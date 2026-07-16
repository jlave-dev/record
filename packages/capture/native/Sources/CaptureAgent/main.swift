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
        var state = CaptureState(token: request.token, status: .starting, requestedApp: requestedApp, outputDir: outputDir, outputPath: outputURL.path, metadataPath: metadataURL.path)
        state.pid = Int32(ProcessInfo.processInfo.processIdentifier)
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
            try writeJSON(state, to: CapturePaths.state)

            var nextSourceRefresh = Date()
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

            let stoppedAt = nowISO8601()
            let metadata = CaptureMetadata(
                appName: application.applicationName,
                bundleID: application.bundleIdentifier,
                outputPath: outputURL.path,
                metadataPath: metadataURL.path,
                width: dimensions.width,
                height: dimensions.height,
                startedAt: state.startedAt!,
                stoppedAt: stoppedAt
            )
            try writeJSON(metadata, to: metadataURL)
            state.status = .stopped
            state.stoppedAt = stoppedAt
            try writeJSON(state, to: CapturePaths.state)
            try? FileManager.default.removeItem(at: CapturePaths.stop)
        } catch {
            if captureStarted { try? await stream.stopCapture() }
            if audioCaptureStarted { try? await audioStream?.stopCapture() }
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
