import Foundation
import LiveCore

@main
struct LiveCLI {
    static func main() {
        do {
            var arguments = Array(CommandLine.arguments.dropFirst())
            let command = arguments.isEmpty ? "help" : arguments.removeFirst()
            switch command {
            case "start": try start(arguments)
            case "status": try passthroughCapture(command: "status", arguments: arguments)
            case "stop": try passthroughCapture(command: "stop", arguments: arguments)
            case "next": try next(arguments)
            case "setup": try runWorker(command: "setup", arguments: arguments)
            case "doctor": try doctor(arguments)
            case "help", "--help", "-h": printHelp()
            case "--version", "-V": print("0.4.1")
            default: throw LiveError("unknown live command: \(command)")
            }
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func start(_ inputArguments: [String]) throws {
        var arguments = inputArguments
        guard let app = takeOption("--app", from: &arguments) else {
            throw LiveError("live start requires --app APP")
        }
        let json = takeFlag("--json", from: &arguments)
        let output = takeOption("--output", from: &arguments) ?? defaultOutputDirectory(app: app)
        guard arguments.isEmpty else { throw LiveError("unknown live start argument: \(arguments[0])") }

        let worker = try workerExecutable()
        let events = URL(fileURLWithPath: output).appendingPathComponent("live-transcript.jsonl").path
        var captureArguments = [
            "start", "--app", app, "--output", output,
            "--live-worker", worker.path, "--live-events", events,
        ]
        if json { captureArguments.append("--json") }
        try runAndForward(captureExecutable(), captureArguments)
    }

    private static func passthroughCapture(command: String, arguments: [String]) throws {
        var arguments = arguments
        let json = takeFlag("--json", from: &arguments)
        guard arguments.isEmpty else { throw LiveError("live \(command) does not accept that argument") }
        if try captureState().liveEventsPath == nil {
            throw LiveError("no live capture is currently active")
        }
        try runAndForward(captureExecutable(), [command] + (json ? ["--json"] : []))
    }

    private static func next(_ inputArguments: [String]) throws {
        var arguments = inputArguments
        guard let afterValue = takeOption("--after", from: &arguments),
              let after = Int(afterValue), after >= 0 else {
            throw LiveError("live next requires --after CURSOR")
        }
        let timeoutValue = takeOption("--timeout", from: &arguments) ?? "30"
        guard let timeout = Double(timeoutValue), timeout >= 0 else {
            throw LiveError("--timeout requires non-negative seconds")
        }
        _ = takeFlag("--json", from: &arguments)
        guard arguments.isEmpty else { throw LiveError("unknown live next argument: \(arguments[0])") }

        let state = try captureState()
        guard let eventsPath = state.liveEventsPath else { throw LiveError("no live transcript is available") }
        let eventsURL = URL(fileURLWithPath: eventsPath)
        let deadline = Date().addingTimeInterval(timeout)
        var events: [TranscriptEvent] = []
        repeat {
            events = try EventLogReader.read(url: eventsURL, after: after)
            if !events.isEmpty { break }
            if Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        } while Date() < deadline

        let nextCursor = events.last?.cursor ?? after
        let terminal = state.liveStatus == "stopped" || state.liveStatus == "failed" || events.contains { $0.type == "live.stopped" || $0.type == "live.failed" }
        printJSON(NextPayload(events: events, nextCursor: nextCursor, terminal: terminal))
    }

    private static func doctor(_ arguments: [String]) throws {
        var arguments = arguments
        _ = takeFlag("--json", from: &arguments)
        guard arguments.isEmpty else { throw LiveError("live doctor does not accept that argument") }
        let capture = captureExecutable()
        let worker = try workerExecutable()
        let workerResult = run(worker, ["doctor"])
        let checks = [
            Check(name: "capture_runtime", ok: FileManager.default.isExecutableFile(atPath: capture.path), details: capture.path),
            Check(name: "live_worker", ok: workerResult.status == 0, details: workerResult.status == 0 ? "FluidAudio model is ready." : workerResult.stderr),
        ]
        printJSON(DoctorPayload(ok: checks.allSatisfy(\.ok), checks: checks))
        if !checks.allSatisfy(\.ok) { exit(1) }
    }

    private static func runWorker(command: String, arguments: [String]) throws {
        var arguments = arguments
        _ = takeFlag("--json", from: &arguments)
        guard arguments.isEmpty else { throw LiveError("live \(command) does not accept that argument") }
        try runAndForward(try workerExecutable(), [command])
    }

    private static func captureState() throws -> CaptureStatePayload {
        let result = run(captureExecutable(), ["status", "--json"])
        guard result.status == 0 else { throw LiveError(result.stderr) }
        guard let state = try? JSONDecoder().decode(CaptureStatePayload.self, from: result.stdoutData) else {
            throw LiveError("no live capture state is available")
        }
        return state
    }

    private static func captureExecutable() -> URL {
        if let override = ProcessInfo.processInfo.environment["RECORD_CAPTURE_RUNTIME"] {
            return URL(fileURLWithPath: override)
        }
        return executableDirectory().deletingLastPathComponent().appendingPathComponent("capture/capture")
    }

    private static func workerExecutable() throws -> URL {
        let url = ProcessInfo.processInfo.environment["RECORD_LIVE_WORKER"]
            .map(URL.init(fileURLWithPath:)) ?? executableDirectory().appendingPathComponent("live-worker")
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw LiveError("live worker was not found at \(url.path)")
        }
        return url
    }

    private static func executableDirectory() -> URL {
        URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent()
    }

    private static func runAndForward(_ executable: URL, _ arguments: [String]) throws {
        let result = run(executable, arguments)
        FileHandle.standardOutput.write(result.stdoutData)
        if !result.stderr.isEmpty { FileHandle.standardError.write(Data(result.stderr.utf8)) }
        guard result.status == 0 else { throw LiveError("live command failed") }
    }

    private static func run(_ executable: URL, _ arguments: [String]) -> ProcessResult {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        do { try process.run() } catch {
            return ProcessResult(status: 127, stdoutData: Data(), stderr: error.localizedDescription)
        }
        process.waitUntilExit()
        return ProcessResult(
            status: process.terminationStatus,
            stdoutData: stdout.fileHandleForReading.readDataToEndOfFile(),
            stderr: String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        )
    }

    private static func takeFlag(_ name: String, from arguments: inout [String]) -> Bool {
        guard let index = arguments.firstIndex(of: name) else { return false }
        arguments.remove(at: index)
        return true
    }

    private static func takeOption(_ name: String, from arguments: inout [String]) -> String? {
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
        let value = arguments[index + 1]
        arguments.removeSubrange(index...index + 1)
        return value
    }

    private static func defaultOutputDirectory(app: String) -> String {
        let formatter = ISO8601DateFormatter()
        let timestamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let safeApp = app.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Movies/record-live")
            .appendingPathComponent("\(timestamp)-\(safeApp.isEmpty ? "app" : safeApp)")
            .path
    }

    private static func printJSON<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(value) + Data([0x0a]) { FileHandle.standardOutput.write(data) }
    }

    private static func printHelp() {
        print("""
        Usage: live <command> [options]

          live start --app APP [--output DIR] [--json]
          live status [--json]
          live next --after CURSOR [--timeout SECONDS] --json
          live stop [--json]
          live setup [--json]
          live doctor [--json]
        """)
    }
}

private struct CaptureStatePayload: Decodable {
    let liveEventsPath: String?
    let liveStatus: String?
}

private struct NextPayload: Encodable {
    let events: [TranscriptEvent]
    let nextCursor: Int
    let terminal: Bool
}

private struct Check: Encodable {
    let name: String
    let ok: Bool
    let details: String
}

private struct DoctorPayload: Encodable {
    let ok: Bool
    let checks: [Check]
}

private struct ProcessResult {
    let status: Int32
    let stdoutData: Data
    let stderr: String
}
