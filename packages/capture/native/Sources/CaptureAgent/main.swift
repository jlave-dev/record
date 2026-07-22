import AVFoundation
import CaptureCore
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

actor RecordingEvents {
    enum Status {
        case waiting
        case started
        case finished
        case failed(String)
    }

    private var status: Status = .waiting

    func markStarted() { status = .started }
    func markFinished() { status = .finished }
    func markFailed(_ message: String) { status = .failed(message) }
    func snapshot() -> Status { status }
}

final class CaptureDelegate: NSObject, SCRecordingOutputDelegate, SCStreamDelegate {
    let events: RecordingEvents

    init(events: RecordingEvents) {
        self.events = events
    }

    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        Task { await events.markStarted() }
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { await events.markFailed(error.localizedDescription) }
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { await events.markFinished() }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { await events.markFailed(error.localizedDescription) }
    }
}

private final class LiveWorkerProcess {
    let process = Process()
    let input = Pipe()
    private let readyURL: URL
    private let logHandle: FileHandle

    init(executable: URL, eventsURL: URL, outputDirectory: URL) throws {
        readyURL = outputDirectory.appendingPathComponent(".live-worker-ready")
        let logURL = outputDirectory.appendingPathComponent("live-worker.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        logHandle = try FileHandle(forWritingTo: logURL)
        try? FileManager.default.removeItem(at: readyURL)

        process.executableURL = executable
        process.arguments = ["stream", "--events", eventsURL.path, "--ready", readyURL.path]
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = logHandle
        try process.run()
    }

    var processIdentifier: Int32 { process.processIdentifier }

    func waitUntilReady(timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: readyURL.path) {
                try? FileManager.default.removeItem(at: readyURL)
                return
            }
            if !process.isRunning {
                throw CaptureCoreError.message("Live transcription worker exited during startup. See live-worker.log.")
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw CaptureCoreError.message("Timed out preparing live transcription. Run `record live setup` before retrying.")
    }

    func finish(timeout: TimeInterval = 30) throws {
        try? input.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if process.isRunning {
            process.terminate()
            throw CaptureCoreError.message("Live transcription worker did not stop after its audio stream ended.")
        }
        try? logHandle.close()
        guard process.terminationStatus == 0 else {
            throw CaptureCoreError.message("Live transcription worker failed. See live-worker.log.")
        }
    }

    func cancel() {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        try? logHandle.close()
        try? FileManager.default.removeItem(at: readyURL)
    }
}

private final class LiveAudioForwarder: NSObject, SCStreamOutput {
    struct Snapshot {
        let delivered: Int
        let dropped: Int
        let error: String?
    }

    private let input: FileHandle
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private let writerQueue = DispatchQueue(label: "dev.record.live-audio-writer")
    private let pending = DispatchSemaphore(value: 16)
    private let writes = DispatchGroup()
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var firstPresentationTime: CMTime?
    private var delivered = 0
    private var dropped = 0
    private var failure: String?

    init(input: FileHandle) {
        self.input = input
        super.init()
        _ = fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .audio, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        do {
            let frame = try encodedFrame(from: sampleBuffer)
            guard pending.wait(timeout: .now()) == .success else {
                lock.withLock { dropped += 1 }
                return
            }
            writes.enter()
            writerQueue.async { [self] in
                defer {
                    pending.signal()
                    writes.leave()
                }
                do {
                    try input.write(contentsOf: frame)
                    lock.withLock { delivered += 1 }
                } catch {
                    lock.withLock {
                        dropped += 1
                        if failure == nil { failure = error.localizedDescription }
                    }
                }
            }
        } catch {
            lock.withLock {
                dropped += 1
                if failure == nil { failure = error.localizedDescription }
            }
        }
    }

    func finish() -> Snapshot {
        writes.wait()
        return snapshot()
    }

    func snapshot() -> Snapshot {
        lock.withLock { Snapshot(delivered: delivered, dropped: dropped, error: failure) }
    }

    private func encodedFrame(from sampleBuffer: CMSampleBuffer) throws -> Data {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
              let inputFormat = AVAudioFormat(streamDescription: streamDescription) else {
            throw CaptureCoreError.message("Live audio has no supported format description.")
        }
        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0,
              let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCount) else {
            throw CaptureCoreError.message("Could not allocate a live audio input buffer.")
        }
        inputBuffer.frameLength = frameCount
        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: inputBuffer.mutableAudioBufferList
        )
        guard copyStatus == noErr else {
            throw CaptureCoreError.message("Could not read live audio samples (\(copyStatus)).")
        }

        if converter == nil || converterInputFormat != inputFormat {
            converter = AVAudioConverter(from: inputFormat, to: outputFormat)
            converterInputFormat = inputFormat
        }
        guard let converter else { throw CaptureCoreError.message("Could not create the live audio converter.") }
        let capacity = AVAudioFrameCount(ceil(Double(frameCount) * outputFormat.sampleRate / inputFormat.sampleRate)) + 32
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw CaptureCoreError.message("Could not allocate a live audio output buffer.")
        }
        var suppliedInput = false
        var conversionError: NSError?
        let conversionStatus = converter.convert(to: outputBuffer, error: &conversionError) { _, status in
            if suppliedInput {
                status.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            status.pointee = .haveData
            return inputBuffer
        }
        guard conversionStatus != .error, conversionError == nil,
              let channel = outputBuffer.floatChannelData?[0] else {
            throw conversionError ?? CaptureCoreError.message("Could not convert live audio to 16 kHz mono.")
        }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if firstPresentationTime == nil { firstPresentationTime = presentationTime }
        let sourceAudioMs = max(0, Int64((CMTimeGetSeconds(presentationTime - firstPresentationTime!) * 1000).rounded()))
        let sampleCount = Int(outputBuffer.frameLength)
        var data = Data()
        append(UInt32(0x524C4956), to: &data)
        append(UInt32(1), to: &data)
        append(sourceAudioMs, to: &data)
        append(UInt32(sampleCount), to: &data)
        data.append(UnsafeBufferPointer(start: channel, count: sampleCount))
        return data
    }

    private func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}

private enum CaptureSourceKey: Equatable {
    case application(CGDirectDisplayID)
    case zoomShare(CGDirectDisplayID, CGRect)
    case zoomWindowShare(CGDirectDisplayID, CGWindowID, CGRect)
}

private struct CaptureSource {
    let key: CaptureSourceKey
    let filter: SCContentFilter
    let audioFilter: SCContentFilter
    let sourceRect: CGRect
}

@main
struct CaptureAgent {
    static let zoomBundleID = "us.zoom.xos"

    static func main() async {
        var request: CaptureRequest?
        do {
            guard let requestIndex = CommandLine.arguments.firstIndex(of: "--request"), requestIndex + 1 < CommandLine.arguments.count else {
                throw CaptureCoreError.message("Capture agent requires --request PATH.")
            }
            let requestURL = URL(fileURLWithPath: CommandLine.arguments[requestIndex + 1])
            request = try readJSON(CaptureRequest.self, from: requestURL)
            guard let request else { return }
            switch request.action {
            case .start:
                try await record(request)
            case .apps:
                try await listApps(request)
            case .doctor:
                try doctor(request)
            case .setup:
                try setup(request)
            }
        } catch {
            if let responsePath = request?.responsePath {
                let response: [String: Any] = ["ok": false, "error": error.localizedDescription]
                if let data = try? JSONSerialization.data(withJSONObject: response, options: [.prettyPrinted, .sortedKeys]) + Data([0x0a]) {
                    try? data.write(to: URL(fileURLWithPath: responsePath), options: [.atomic])
                }
            }
            if request?.action == .start, let state = try? readJSON(CaptureState.self, from: CapturePaths.state) {
                var failed = state
                failed.status = .failed
                failed.pid = Int32(ProcessInfo.processInfo.processIdentifier)
                failed.error = error.localizedDescription
                try? writeJSON(failed, to: CapturePaths.state)
            }
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    static func record(_ request: CaptureRequest) async throws {
        guard let requestedApp = request.app, let outputDir = request.outputDir else {
            throw CaptureCoreError.message("Start request is missing app or output directory.")
        }
        let outputURL = URL(fileURLWithPath: outputDir).appendingPathComponent("recording.mp4")
        let metadataURL = URL(fileURLWithPath: outputDir).appendingPathComponent("metadata.json")
        let outputDirectoryURL = URL(fileURLWithPath: outputDir)
        var state = CaptureState(token: request.token, status: .starting, requestedApp: requestedApp, outputDir: outputDir, outputPath: outputURL.path, metadataPath: metadataURL.path)
        state.pid = Int32(ProcessInfo.processInfo.processIdentifier)
        state.liveEventsPath = request.liveEventsPath
        state.liveStatus = request.liveEventsPath == nil ? nil : .starting
        try writeJSON(state, to: CapturePaths.state)

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let descriptors = content.applications.map { AppDescriptor(name: $0.applicationName, bundleID: $0.bundleIdentifier, processID: $0.processID) }
        guard let descriptor = resolveApp(requestedApp, from: descriptors),
              let application = content.applications.first(where: { $0.processID == descriptor.processID }) else {
            let candidates = descriptors.filter { $0.name.lowercased().contains(requestedApp.lowercased()) }.map(\.name).joined(separator: ", ")
            throw CaptureCoreError.message(candidates.isEmpty ? "Could not resolve shareable app \"\(requestedApp)\"." : "App \"\(requestedApp)\" is ambiguous: \(candidates)")
        }
        var source = try captureSource(for: application, content: content)
        let info = SCShareableContent.info(for: source.filter)
        let sourceSize = source.sourceRect.isEmpty ? info.contentRect.size : source.sourceRect.size
        let dimensions = try recordingDimensions(
            sourceWidth: sourceSize.width * CGFloat(info.pointPixelScale),
            sourceHeight: sourceSize.height * CGFloat(info.pointPixelScale),
            requestedWidth: request.width,
            requestedHeight: request.height
        )

        let configuration = SCStreamConfiguration()
        configuration.width = dimensions.width
        configuration.height = dimensions.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 5
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        configuration.showsCursor = true
        configuration.sourceRect = source.sourceRect
        let usesSeparateZoomAudio = application.bundleIdentifier == zoomBundleID
        configuration.capturesAudio = !usesSeparateZoomAudio
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2

        let events = RecordingEvents()
        let delegate = CaptureDelegate(events: events)
        let stream = SCStream(filter: source.filter, configuration: configuration, delegate: delegate)
        let recordingConfiguration = SCRecordingOutputConfiguration()
        recordingConfiguration.outputURL = outputURL
        recordingConfiguration.outputFileType = .mp4
        recordingConfiguration.videoCodecType = .h264
        let recordingOutput = SCRecordingOutput(configuration: recordingConfiguration, delegate: delegate)
        try stream.addRecordingOutput(recordingOutput)

        let audioOutputURL = URL(fileURLWithPath: outputDir).appendingPathComponent(".zoom-audio.mp4")
        var audioStream: SCStream?
        var audioEvents: RecordingEvents?
        var audioDelegate: CaptureDelegate?
        if usesSeparateZoomAudio {
            // The share-video filter hides Zoom windows, so preserve meeting audio on its own stream.
            let audioConfiguration = SCStreamConfiguration()
            audioConfiguration.width = 2
            audioConfiguration.height = 2
            audioConfiguration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            audioConfiguration.queueDepth = 2
            audioConfiguration.showsCursor = false
            audioConfiguration.capturesAudio = true
            audioConfiguration.excludesCurrentProcessAudio = true
            audioConfiguration.sampleRate = 48_000
            audioConfiguration.channelCount = 2

            let events = RecordingEvents()
            let delegate = CaptureDelegate(events: events)
            let zoomAudioStream = SCStream(filter: source.audioFilter, configuration: audioConfiguration, delegate: delegate)
            let zoomAudioRecordingConfiguration = SCRecordingOutputConfiguration()
            zoomAudioRecordingConfiguration.outputURL = audioOutputURL
            zoomAudioRecordingConfiguration.outputFileType = .mp4
            zoomAudioRecordingConfiguration.videoCodecType = .h264
            try zoomAudioStream.addRecordingOutput(SCRecordingOutput(configuration: zoomAudioRecordingConfiguration, delegate: delegate))
            audioStream = zoomAudioStream
            audioEvents = events
            audioDelegate = delegate
        }
        defer { _ = audioDelegate }

        var liveWorker: LiveWorkerProcess?
        var liveForwarder: LiveAudioForwarder?
        let liveAudioQueue = DispatchQueue(label: "dev.record.live-audio-capture")
        if request.liveWorkerPath != nil || request.liveEventsPath != nil {
            guard let workerPath = request.liveWorkerPath, let eventsPath = request.liveEventsPath else {
                throw CaptureCoreError.message("Live capture request is missing its worker or event path.")
            }
            let worker = try LiveWorkerProcess(
                executable: URL(fileURLWithPath: workerPath),
                eventsURL: URL(fileURLWithPath: eventsPath),
                outputDirectory: outputDirectoryURL
            )
            liveWorker = worker
            state.liveWorkerPID = worker.processIdentifier
            try writeJSON(state, to: CapturePaths.state)
            do {
                try worker.waitUntilReady(timeout: 180)
                let forwarder = LiveAudioForwarder(input: worker.input.fileHandleForWriting)
                if let audioStream {
                    try audioStream.addStreamOutput(forwarder, type: .audio, sampleHandlerQueue: liveAudioQueue)
                } else {
                    try stream.addStreamOutput(forwarder, type: .audio, sampleHandlerQueue: liveAudioQueue)
                }
                liveForwarder = forwarder
            } catch {
                worker.cancel()
                throw error
            }
        }

        var captureStarted = false
        var audioCaptureStarted = false
        do {
            if let audioStream {
                async let startVideo: Void = stream.startCapture()
                async let startAudio: Void = audioStream.startCapture()
                _ = try await (startVideo, startAudio)
                audioCaptureStarted = true
            } else {
                try await stream.startCapture()
            }
            captureStarted = true
            try await waitForEvent(events, wanted: .started, timeout: 15)
            if let audioEvents { try await waitForEvent(audioEvents, wanted: .started, timeout: 15) }

            state.status = .recording
            state.appName = application.applicationName
            state.bundleID = application.bundleIdentifier
            state.width = dimensions.width
            state.height = dimensions.height
            state.startedAt = nowISO8601()
            state.liveStatus = liveForwarder == nil ? nil : .running
            try writeJSON(state, to: CapturePaths.state)

            var nextSourceRefresh = Date()
            var nextLiveStateRefresh = Date().addingTimeInterval(1)
            while true {
                if let stopToken = try? String(contentsOf: CapturePaths.stop, encoding: .utf8), stopToken == request.token { break }
                if case .failed(let message) = await events.snapshot() { throw CaptureCoreError.message(message) }
                if application.bundleIdentifier == zoomBundleID, Date() >= nextSourceRefresh {
                    nextSourceRefresh = Date().addingTimeInterval(0.5)
                    if let refreshedContent = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
                       let refreshedApplication = refreshedContent.applications.first(where: { $0.processID == application.processID }),
                       let desiredSource = try? captureSource(for: refreshedApplication, content: refreshedContent),
                       desiredSource.key != source.key {
                        do {
                            if let audioStream { try await audioStream.updateContentFilter(desiredSource.audioFilter) }
                            try await stream.updateContentFilter(desiredSource.filter)
                            configuration.sourceRect = desiredSource.sourceRect
                            try await stream.updateConfiguration(configuration)
                            source = desiredSource
                        } catch {
                            FileHandle.standardError.write(Data("Could not follow Zoom share: \(error.localizedDescription)\n".utf8))
                        }
                    }
                }
                if let liveForwarder, Date() >= nextLiveStateRefresh {
                    nextLiveStateRefresh = Date().addingTimeInterval(1)
                    let snapshot = liveForwarder.snapshot()
                    state.liveFramesDelivered = snapshot.delivered
                    state.liveFramesDropped = snapshot.dropped
                    if let failure = snapshot.error {
                        state.liveStatus = .failed
                        state.liveError = failure
                    }
                    try writeJSON(state, to: CapturePaths.state)
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }

            state.status = .stopping
            try writeJSON(state, to: CapturePaths.state)
            if let audioStream {
                async let stopVideo: Void = stream.stopCapture()
                async let stopAudio: Void = audioStream.stopCapture()
                _ = try await (stopVideo, stopAudio)
                audioCaptureStarted = false
            } else {
                try await stream.stopCapture()
            }
            captureStarted = false
            try await waitForEvent(events, wanted: .finished, timeout: 15)
            if let audioEvents {
                try await waitForEvent(audioEvents, wanted: .finished, timeout: 15)
                try await replaceAudio(in: outputURL, withAudioFrom: audioOutputURL)
                try? FileManager.default.removeItem(at: audioOutputURL)
            }

            if let liveForwarder, let liveWorker {
                let snapshot = liveForwarder.finish()
                state.liveFramesDelivered = snapshot.delivered
                state.liveFramesDropped = snapshot.dropped
                if let failure = snapshot.error {
                    state.liveStatus = .failed
                    state.liveError = failure
                }
                do {
                    try liveWorker.finish()
                    if state.liveError == nil {
                        state.liveStatus = .stopped
                    }
                } catch {
                    state.liveStatus = .failed
                    state.liveError = state.liveError ?? error.localizedDescription
                }
            }

            let stoppedAt = nowISO8601()
            let metadata = CaptureMetadata(
                appName: application.applicationName,
                bundleID: application.bundleIdentifier,
                outputPath: outputURL.path,
                metadataPath: metadataURL.path,
                width: dimensions.width,
                height: dimensions.height,
                startedAt: state.startedAt!,
                stoppedAt: stoppedAt,
                liveEventsPath: state.liveEventsPath,
                liveFramesDelivered: state.liveFramesDelivered,
                liveFramesDropped: state.liveFramesDropped,
                liveError: state.liveError
            )
            try writeJSON(metadata, to: metadataURL)
            state.status = .stopped
            state.stoppedAt = stoppedAt
            try writeJSON(state, to: CapturePaths.state)
            try? FileManager.default.removeItem(at: CapturePaths.stop)
        } catch {
            if captureStarted { try? await stream.stopCapture() }
            if audioCaptureStarted { try? await audioStream?.stopCapture() }
            liveWorker?.cancel()
            try? FileManager.default.removeItem(at: audioOutputURL)
            state.status = .failed
            state.error = error.localizedDescription
            state.stoppedAt = nowISO8601()
            try? writeJSON(state, to: CapturePaths.state)
            throw error
        }
    }

    private static func captureSource(for application: SCRunningApplication, content: SCShareableContent) throws -> CaptureSource {
        if application.bundleIdentifier == zoomBundleID, let source = zoomShareSource(for: application, content: content) {
            return source
        }
        guard let display = bestDisplay(for: application, content: content) else {
            throw CaptureCoreError.message("No display contains a visible window for \(application.applicationName).")
        }
        return CaptureSource(
            key: .application(display.displayID),
            filter: SCContentFilter(display: display, including: [application], exceptingWindows: []),
            audioFilter: SCContentFilter(display: display, including: [application], exceptingWindows: []),
            sourceRect: .zero
        )
    }

    private static func zoomShareSource(for application: SCRunningApplication, content: SCShareableContent) -> CaptureSource? {
        // ponytail: Zoom has no public share-source API; add a Zoom SDK adapter if overlay titles stop being stable.
        let windows = content.windows.filter { $0.owningApplication?.processID == application.processID }
        let sharing = windows.contains { $0.title?.lowercased() == "zoom share statusbar window" }
        guard sharing,
              let overlay = windows.filter({ $0.title?.lowercased() == "annotation - zoom" && $0.frame.width > 100 && $0.frame.height > 100 })
                .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }),
              let displayIndex = bestOverlappingDisplayIndex(for: overlay.frame, displayFrames: content.displays.map(\.frame)) else {
            return nil
        }

        let display = content.displays[displayIndex]
        guard let sourceRect = localCaptureRect(for: overlay.frame, in: display.frame) else { return nil }
        if let sharedProcessID = content.windows.first(where: {
            $0.title?.lowercased() == "window" &&
                $0.owningApplication?.processID != application.processID &&
                isZoomWindowShareMarker($0.frame, inside: overlay.frame)
        })?.owningApplication?.processID {
            let candidateWindows = content.windows.filter {
                $0.owningApplication?.processID == sharedProcessID &&
                    $0.frame.width > 100 && $0.frame.height > 100 &&
                    intersectionArea($0.frame, display.frame) > 0
            }
            if let sharedWindowIndex = bestMatchingWindowIndex(for: overlay.frame, windowFrames: candidateWindows.map(\.frame)),
               let sharedApplication = candidateWindows[sharedWindowIndex].owningApplication {
                let sharedWindow = candidateWindows[sharedWindowIndex]
                return CaptureSource(
                    key: .zoomWindowShare(display.displayID, sharedWindow.windowID, .zero),
                    filter: SCContentFilter(desktopIndependentWindow: sharedWindow),
                    audioFilter: SCContentFilter(display: display, including: [application, sharedApplication], exceptingWindows: []),
                    sourceRect: .zero
                )
            }
        }

        let zoomWindowsOnDisplay = windows.filter { intersectionArea($0.frame, display.frame) > 0 }
        return CaptureSource(
            key: .zoomShare(display.displayID, sourceRect),
            filter: SCContentFilter(display: display, excludingApplications: [], exceptingWindows: zoomWindowsOnDisplay),
            audioFilter: SCContentFilter(display: display, excludingApplications: [], exceptingWindows: []),
            sourceRect: sourceRect
        )
    }

    private static func replaceAudio(in videoURL: URL, withAudioFrom audioURL: URL) async throws {
        let videoAsset = AVURLAsset(url: videoURL)
        let audioAsset = AVURLAsset(url: audioURL)
        guard let sourceVideo = try await videoAsset.loadTracks(withMediaType: .video).first,
              let sourceAudio = try await audioAsset.loadTracks(withMediaType: .audio).first else {
            throw CaptureCoreError.message("Zoom audio recording did not contain an audio track.")
        }

        let videoDuration = try await videoAsset.load(.duration)
        let audioDuration = try await audioAsset.load(.duration)
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw CaptureCoreError.message("Could not create the final Zoom recording tracks.")
        }
        try videoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: videoDuration), of: sourceVideo, at: .zero)
        try audioTrack.insertTimeRange(CMTimeRange(start: .zero, duration: CMTimeMinimum(videoDuration, audioDuration)), of: sourceAudio, at: .zero)

        let mergedURL = videoURL.deletingLastPathComponent().appendingPathComponent(".recording-with-audio.mp4")
        try? FileManager.default.removeItem(at: mergedURL)
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw CaptureCoreError.message("Could not create the final Zoom recording.")
        }
        try await export.export(to: mergedURL, as: .mp4)
        _ = try FileManager.default.replaceItemAt(videoURL, withItemAt: mergedURL)
    }

    static func bestDisplay(for application: SCRunningApplication, content: SCShareableContent) -> SCDisplay? {
        let windows = content.windows.filter { $0.owningApplication?.processID == application.processID && $0.frame.width > 0 && $0.frame.height > 0 }
        guard let largestWindow = windows.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
            return content.displays.first
        }
        return content.displays.max { left, right in
            intersectionArea(left.frame, largestWindow.frame) < intersectionArea(right.frame, largestWindow.frame)
        }
    }

    static func intersectionArea(_ left: CGRect, _ right: CGRect) -> CGFloat {
        let intersection = left.intersection(right)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }

    enum WantedEvent { case started, finished }

    static func waitForEvent(_ events: RecordingEvents, wanted: WantedEvent, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            switch await events.snapshot() {
            case .started where wanted == .started: return
            case .finished where wanted == .finished: return
            case .failed(let message): throw CaptureCoreError.message(message)
            default: break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw CaptureCoreError.message("Timed out waiting for recording to \(wanted == .started ? "start" : "finish").")
    }

    static func listApps(_ request: CaptureRequest) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let apps = content.applications
            .map { AppDescriptor(name: $0.applicationName, bundleID: $0.bundleIdentifier, processID: $0.processID) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        try writeResponse(["apps": apps], request: request)
    }

    static func doctor(_ request: CaptureRequest) throws {
        let permission = CGPreflightScreenCaptureAccess()
        let response: [String: Any] = [
            "ok": permission,
            "checks": [
                ["name": "macos", "ok": true, "details": "ScreenCaptureKit recording requires macOS 15 or newer."],
                ["name": "screen_recording_permission", "ok": permission, "details": permission ? "Screen & System Audio Recording permission is granted." : "Screen & System Audio Recording permission is not granted; run capture setup."]
            ]
        ]
        try writeJSONObject(response, request: request)
    }

    static func setup(_ request: CaptureRequest) throws {
        let granted = CGRequestScreenCaptureAccess()
        let response: [String: Any] = [
            "ok": granted,
            "permission_granted": granted,
            "next": granted ? "capture doctor" : "Allow CaptureAgent in System Settings > Privacy & Security > Screen & System Audio Recording, then retry."
        ]
        try writeJSONObject(response, request: request)
    }

    static func writeResponse<T: Encodable>(_ response: T, request: CaptureRequest) throws {
        guard let responsePath = request.responsePath else { throw CaptureCoreError.message("Request is missing a response path.") }
        try writeJSON(response, to: URL(fileURLWithPath: responsePath))
    }

    static func writeJSONObject(_ response: [String: Any], request: CaptureRequest) throws {
        guard let responsePath = request.responsePath else { throw CaptureCoreError.message("Request is missing a response path.") }
        let data = try JSONSerialization.data(withJSONObject: response, options: [.prettyPrinted, .sortedKeys]) + Data([0x0a])
        try data.write(to: URL(fileURLWithPath: responsePath), options: [.atomic])
    }
}
