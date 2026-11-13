import AVFoundation
import AppKit
import CaptureCore
import ScreenCaptureKit
import XCTest
@testable import CaptureAgent

final class RecordingTests: XCTestCase {
    // Opt-in because this creates a visible test window and requires screen
    // recording permission: CAPTURE_INTEGRATION=1 npm --workspace capture test
    @MainActor
    func testLiveConfigurationChangesKeepWriting() async throws {
        guard ProcessInfo.processInfo.environment["CAPTURE_INTEGRATION"] == "1" else {
            throw XCTSkip("Set CAPTURE_INTEGRATION=1 to exercise ScreenCaptureKit with a synthetic window.")
        }
        guard CGPreflightScreenCaptureAccess() else { throw XCTSkip("Screen recording permission is required.") }
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 320, height: 240),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Record capture regression test"
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.backgroundColor = NSColor.red.cgColor
        window.orderFrontRegardless()
        defer { window.close() }
        try await Task.sleep(nanoseconds: 500_000_000)
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let capturedWindow = try XCTUnwrap(content.windows.first { $0.windowID == CGWindowID(window.windowNumber) })
        let application = try XCTUnwrap(capturedWindow.owningApplication)
        let display = try XCTUnwrap(content.displays.first)
        let windowFilter = SCContentFilter(desktopIndependentWindow: capturedWindow)
        let appFilter = SCContentFilter(display: display, including: [application], exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = 320
        configuration.height = 240
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.scalesToFit = true
        configuration.queueDepth = 5
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Reproduce the original failure using Apple's built-in recording output.
        let oldEvents = RecordingEvents()
        let oldDelegate = CaptureDelegate(events: oldEvents)
        let oldStream = SCStream(filter: windowFilter, configuration: configuration, delegate: oldDelegate)
        let outputConfiguration = SCRecordingOutputConfiguration()
        outputConfiguration.outputURL = directory.appendingPathComponent("before.mp4")
        try oldStream.addRecordingOutput(SCRecordingOutput(configuration: outputConfiguration, delegate: oldDelegate))
        try await oldStream.startCapture()
        do {
            try await CaptureAgent.waitForEvent(oldEvents, wanted: .started, timeout: 15)
            configuration.sourceRect = CGRect(x: 0, y: 0, width: 160, height: 120)
            try await oldStream.updateConfiguration(configuration)
            try await CaptureAgent.waitForEvent(oldEvents, wanted: .finished, timeout: 15)
            XCTAssertThrowsError(try oldEvents.checkRecording("Video recording"))
            try await oldStream.stopCapture()
        } catch {
            try? await oldStream.stopCapture()
            throw error
        }

        // The replacement must survive the same configuration update, repeated
        // window/application switches, and a quiet tail before finalization.
        let events = RecordingEvents()
        let delegate = CaptureDelegate(events: events)
        configuration.sourceRect = .zero
        let stream = SCStream(filter: windowFilter, configuration: configuration, delegate: delegate)
        let url = directory.appendingPathComponent("after.mp4")
        let writer = try ZoomVideoWriter(url: url, width: 320, height: 240, events: events)
        try stream.addStreamOutput(writer, type: .screen, sampleHandlerQueue: writer.queue)
        let audioEvents = RecordingEvents()
        let audioDelegate = CaptureDelegate(events: audioEvents)
        let audioConfiguration = SCStreamConfiguration()
        audioConfiguration.width = 2
        audioConfiguration.height = 2
        audioConfiguration.capturesAudio = true
        let audioStream = SCStream(filter: appFilter, configuration: audioConfiguration, delegate: audioDelegate)
        let audioOutput = SCRecordingOutputConfiguration()
        audioOutput.outputURL = directory.appendingPathComponent("audio.mp4")
        try audioStream.addRecordingOutput(SCRecordingOutput(configuration: audioOutput, delegate: audioDelegate))
        try await audioStream.startCapture()
        try await stream.startCapture()
        do {
            try await CaptureAgent.waitForEvent(events, wanted: .started, timeout: 15)
            try await CaptureAgent.waitForEvent(audioEvents, wanted: .started, timeout: 15)
            for index in 0..<6 {
                try await audioStream.updateContentFilter(appFilter)
                try await stream.updateContentFilter(index.isMultiple(of: 2) ? appFilter : windowFilter)
                configuration.sourceRect = index.isMultiple(of: 2) ? .zero : CGRect(x: 0, y: 0, width: 160, height: 120)
                try await stream.updateConfiguration(configuration)
                window.contentView?.layer?.backgroundColor = index.isMultiple(of: 2) ? NSColor.green.cgColor : NSColor.blue.cgColor
                try await Task.sleep(nanoseconds: 500_000_000)
                try events.checkRecording("Video recording")
                try audioEvents.checkRecording("Zoom audio recording")
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
            try await stream.stopCapture()
            try await audioStream.stopCapture()
            try await writer.finish()
            try await CaptureAgent.waitForEvent(audioEvents, wanted: .finished, timeout: 15)
            try await CaptureAgent.replaceAudio(in: url, withAudioFrom: audioOutput.outputURL)
        } catch {
            try? await stream.stopCapture()
            try? await audioStream.stopCapture()
            try? await writer.finish()
            throw error
        }
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        XCTAssertGreaterThan(duration.seconds, 4)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audioTracks.count, 1)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: CMTime(seconds: 3, preferredTimescale: 600)).image
        XCTAssertEqual(image.width, 320)
        XCTAssertEqual(image.height, 240)
        XCTAssertEqual(events.snapshot(), .finished)
    }

    func testFailureSurvivesLateStartAndFinishCallbacks() {
        let events = RecordingEvents()
        events.markFailed("stream failed")
        events.markFinished()
        events.markStarted()
        events.markFailed("secondary error")
        XCTAssertEqual(events.snapshot(), .failed("stream failed"))
        XCTAssertThrowsError(try events.checkRecording("Video recording"))
    }

    func testUnexpectedFinishIsDetectedForBothOutputs() {
        for label in ["Video recording", "Zoom audio recording"] {
            let events = RecordingEvents()
            events.markStarted()
            XCTAssertNoThrow(try events.checkRecording(label))
            events.markFinished()
            events.markStarted()
            XCTAssertEqual(events.snapshot(), .finished)
            XCTAssertThrowsError(try events.checkRecording(label)) { error in
                XCTAssertTrue(error.localizedDescription.contains(label))
                XCTAssertTrue(error.localizedDescription.contains("incomplete"))
            }
        }
    }

    func testVideoKeepsTimelineAcrossSourceChangesAndIdleTail() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("recording.mp4")
        let events = RecordingEvents()
        let writer = try ZoomVideoWriter(url: url, width: 64, height: 64, events: events)

        // Model complete frames from the meeting, a shared screen, then Zoom
        // again, with idle/blank frames during the switch. Only their content
        // changes: output geometry and the presentation clock stay continuous.
        try writer.queue.sync {
            writer.append(try sample(at: 99, status: .idle))
            XCTAssertEqual(events.snapshot(), .waiting)
            writer.append(try sample(at: 100, value: 40))
            XCTAssertEqual(events.snapshot(), .started)
        }
        // Give the real encoder time to accept each fixture (live callbacks are
        // paced by ScreenCaptureKit); no capture permission is needed here.
        try await Task.sleep(nanoseconds: 100_000_000)
        try writer.queue.sync {
            writer.append(try sample(at: 101, status: .blank))
            writer.append(try sample(at: 102, value: 120))
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        try writer.queue.sync {
            writer.append(try sample(at: 104, value: 220))
            writer.append(try sample(at: 103)) // stale frame must not break writing
        }
        try await writer.finish(at: CMTime(seconds: 110, preferredTimescale: 600))
        XCTAssertEqual(events.snapshot(), .finished)

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, 10, accuracy: 0.05)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var timestamps: [Double] = []
        var colors: [UInt8] = []
        while let buffer = output.copyNextSampleBuffer() {
            timestamps.append(CMSampleBufferGetPresentationTimeStamp(buffer).seconds)
            let pixels = try XCTUnwrap(CMSampleBufferGetImageBuffer(buffer))
            CVPixelBufferLockBaseAddress(pixels, .readOnly)
            colors.append(CVPixelBufferGetBaseAddress(pixels)!.load(as: UInt8.self))
            CVPixelBufferUnlockBaseAddress(pixels, .readOnly)
        }
        XCTAssertEqual(reader.status, .completed)
        XCTAssertEqual(timestamps.count, 4)
        if timestamps.count == 4 {
            XCTAssertEqual(timestamps[0], 0, accuracy: 0.05)
            XCTAssertEqual(timestamps[1], 2, accuracy: 0.05)
            XCTAssertEqual(timestamps[2], 4, accuracy: 0.05)
            XCTAssertEqual(timestamps[3], 10 - 1.0 / 30, accuracy: 0.05)
            for (actual, expected) in zip(colors, [40, 120, 220, 220]) {
                XCTAssertEqual(Double(actual), Double(expected), accuracy: 5)
            }
        }
    }

    func testVideoWithNoCompleteFramesFailsInsteadOfReportingSuccess() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let events = RecordingEvents()
        let writer = try ZoomVideoWriter(url: url, width: 64, height: 64, events: events)
        do {
            try await writer.finish()
            XCTFail("Expected missing-frame failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("no complete frames"))
        }
        XCTAssertThrowsError(try events.checkRecording("Video recording"))
    }

    private func sample(at seconds: Double, status: SCFrameStatus = .complete, value: UInt8 = 80) throws -> CMSampleBuffer {
        var pixels: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels), kCVReturnSuccess)
        let image = try XCTUnwrap(pixels)
        CVPixelBufferLockBaseAddress(image, [])
        memset(CVPixelBufferGetBaseAddress(image), Int32(value), CVPixelBufferGetDataSize(image))
        CVPixelBufferUnlockBaseAddress(image, [])
        var format: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image, formatDescriptionOut: &format), noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 600), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image,
            formatDescription: try XCTUnwrap(format), sampleTiming: &timing, sampleBufferOut: &sample), noErr)
        let buffer = try XCTUnwrap(sample)
        let attachments = try XCTUnwrap(CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true))
        let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        let key = SCStreamFrameInfo.status.rawValue as CFString
        let number = NSNumber(value: status.rawValue)
        CFDictionarySetValue(dictionary, Unmanaged.passUnretained(key).toOpaque(), Unmanaged.passUnretained(number).toOpaque())
        return buffer
    }
}

final class CaptureSessionFailureTests: XCTestCase {
    func testStartupFailureIsPublishedBeforeSessionLockIsReleased() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stateURL = directory.appendingPathComponent("state.json")
        let lockURL = directory.appendingPathComponent("session.lock")
        let request = CaptureRequest(action: .start, token: "old", app: "app", outputDir: directory.path)
        let state = CaptureState(token: "old", status: .starting, requestedApp: "app", outputDir: directory.path, outputPath: "output", metadataPath: "metadata")
        try writeJSON(state, to: stateURL)

        do {
            try await CaptureAgent.withReservedSession(request, stateURL: stateURL, lockURL: lockURL) {
                XCTAssertThrowsError(try CaptureLock(url: lockURL))
                throw CaptureCoreError.message("startup failed")
            }
            XCTFail("Expected startup failure")
        } catch {
            XCTAssertEqual(error.localizedDescription, "startup failed")
        }
        let failed = try readJSON(CaptureState.self, from: stateURL)
        XCTAssertEqual(failed.status, .failed)
        XCTAssertEqual(failed.error, "startup failed")
        let nextLock = try CaptureLock(url: lockURL)
        let next = CaptureState(token: "new", status: .starting, requestedApp: "app", outputDir: directory.path, outputPath: "output", metadataPath: "metadata")
        try writeJSON(next, to: stateURL)
        nextLock.release()

        do {
            try await CaptureAgent.withReservedSession(request, stateURL: stateURL, lockURL: lockURL) {
                XCTFail("A stale request must not start")
            }
            XCTFail("Expected stale reservation to fail")
        } catch {}
        let current = try readJSON(CaptureState.self, from: stateURL)
        XCTAssertEqual(current.token, "new")
        XCTAssertEqual(current.status, .starting)
    }
}
