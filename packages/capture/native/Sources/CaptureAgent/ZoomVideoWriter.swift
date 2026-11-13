import AVFoundation
import CaptureCore
import ScreenCaptureKit

// SCRecordingOutput stops writing when updateConfiguration is called. Zoom share
// transitions need that call to change the crop, so keep its video writer separate
// from the stream. The stream's output dimensions stay fixed for the whole session.
final class ZoomVideoWriter: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "dev.record.zoom-video-writer")
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let events: RecordingEvents
    private var lastSample: CMSampleBuffer?
    private var lastSampleHostTime: CMTime?
    private var finishing = false

    init(url: URL, width: Int, height: Int, events: RecordingEvents) throws {
        self.events = events
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw CaptureCoreError.message("Could not configure Zoom video recording.") }
        writer.add(input)
        super.init()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen else { return }
        append(sampleBuffer)
    }

    func checkHealth() {
        queue.sync {
            if writer.status == .failed || writer.status == .cancelled { fail() }
        }
    }

    // Called on queue, including in tests. Ignore idle/blank/transition frames;
    // their timestamps must not start the file or replace the last complete frame.
    func append(_ sample: CMSampleBuffer) {
        guard !finishing, CMSampleBufferDataIsReady(sample),
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int,
              status == SCFrameStatus.complete.rawValue,
              CMSampleBufferGetImageBuffer(sample) != nil else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        guard time.isNumeric else { return }
        if let lastSample, time <= CMSampleBufferGetPresentationTimeStamp(lastSample) { return }
        if writer.status == .unknown {
            guard writer.startWriting() else { fail(); return }
            writer.startSession(atSourceTime: time)
        }
        guard writer.status == .writing else { fail(); return }
        // Backpressure drops a frame, not the recording. Keep the original clock
        // so dropped frames and source changes never compress the meeting timeline.
        guard input.isReadyForMoreMediaData else { return }
        guard input.append(sample) else { fail(); return }
        lastSample = sample
        lastSampleHostTime = CMClockGetTime(CMClockGetHostTimeClock())
        events.markStarted()
    }

    func finish(at endTime: CMTime? = nil) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard !finishing else {
                    continuation.resume(throwing: CaptureCoreError.message("Zoom video finalization was already requested."))
                    return
                }
                finishing = true
                var finalizationError: Error?
                do {
                    guard let lastSample, let lastSampleHostTime, writer.status == .writing else {
                        throw writer.error ?? CaptureCoreError.message("Zoom video recording has no complete frames.")
                    }
                    let lastTime = CMSampleBufferGetPresentationTimeStamp(lastSample)
                    let frameDuration = CMTime(value: 1, timescale: 30)
                    let end = CMTimeMaximum(lastTime + frameDuration, endTime ??
                        (lastTime + CMClockGetTime(CMClockGetHostTimeClock()) - lastSampleHostTime))
                    // A static shared screen may emit no new frames for minutes.
                    // Repeat its last frame at stop so the MP4 includes that time.
                    if end - frameDuration > lastTime {
                        var timing = CMSampleTimingInfo(duration: frameDuration, presentationTimeStamp: end - frameDuration, decodeTimeStamp: .invalid)
                        var tail: CMSampleBuffer?
                        guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: lastSample,
                            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &tail) == noErr,
                            let tail else { throw CaptureCoreError.message("Could not finalize the last Zoom video frame.") }
                        let deadline = Date().addingTimeInterval(5)
                        while !input.isReadyForMoreMediaData && writer.status == .writing && Date() < deadline {
                            Thread.sleep(forTimeInterval: 0.01)
                        }
                        guard input.isReadyForMoreMediaData, input.append(tail) else {
                            throw writer.error ?? CaptureCoreError.message("Zoom video encoder did not drain while stopping.")
                        }
                    }
                    writer.endSession(atSourceTime: end)
                } catch {
                    events.markFailed(error.localizedDescription)
                    finalizationError = error
                }
                self.lastSample = nil
                guard writer.status == .writing else {
                    continuation.resume(throwing: finalizationError ?? writer.error ?? CaptureCoreError.message("Zoom video writer stopped unexpectedly."))
                    return
                }
                // Even if the tail frame failed, finalize the samples already
                // encoded. Cancelling here would discard the recoverable video.
                input.markAsFinished()
                let priorError = finalizationError
                writer.finishWriting { [self] in
                    if writer.status == .completed, priorError == nil {
                        events.markFinished()
                        continuation.resume()
                    } else {
                        let error = priorError ?? writer.error ?? CaptureCoreError.message("Could not finalize Zoom video recording.")
                        events.markFailed(error.localizedDescription)
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    private func fail() {
        events.markFailed(writer.error?.localizedDescription ?? "Zoom video writer stopped unexpectedly.")
    }
}
