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

@main
struct CaptureAgent {
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
        guard let display = bestDisplay(for: application, content: content) else {
            throw CaptureCoreError.message("No display contains a visible window for \(application.applicationName).")
        }

        let filter = SCContentFilter(display: display, including: [application], exceptingWindows: [])
        let info = SCShareableContent.info(for: filter)
        let dimensions = try recordingDimensions(
            sourceWidth: info.contentRect.width * CGFloat(info.pointPixelScale),
            sourceHeight: info.contentRect.height * CGFloat(info.pointPixelScale),
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
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2

        let events = RecordingEvents()
        let delegate = CaptureDelegate(events: events)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: delegate)
        let recordingConfiguration = SCRecordingOutputConfiguration()
        recordingConfiguration.outputURL = outputURL
        recordingConfiguration.outputFileType = .mp4
        recordingConfiguration.videoCodecType = .h264
        let recordingOutput = SCRecordingOutput(configuration: recordingConfiguration, delegate: delegate)
        try stream.addRecordingOutput(recordingOutput)

        var captureStarted = false
        do {
            try await stream.startCapture()
            captureStarted = true
            try await waitForEvent(events, wanted: .started, timeout: 15)

            state.status = .recording
            state.appName = application.applicationName
            state.bundleID = application.bundleIdentifier
            state.width = dimensions.width
            state.height = dimensions.height
            state.startedAt = nowISO8601()
            try writeJSON(state, to: CapturePaths.state)

            while true {
                if let stopToken = try? String(contentsOf: CapturePaths.stop, encoding: .utf8), stopToken == request.token { break }
                if case .failed(let message) = await events.snapshot() { throw CaptureCoreError.message(message) }
                try await Task.sleep(nanoseconds: 100_000_000)
            }

            state.status = .stopping
            try writeJSON(state, to: CapturePaths.state)
            try await stream.stopCapture()
            captureStarted = false
            try await waitForEvent(events, wanted: .finished, timeout: 15)

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
            state.status = .failed
            state.error = error.localizedDescription
            state.stoppedAt = nowISO8601()
            try? writeJSON(state, to: CapturePaths.state)
            throw error
        }
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
