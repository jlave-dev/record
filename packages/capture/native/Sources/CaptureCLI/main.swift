import CaptureCore
import Darwin
import Foundation

@main
struct CaptureCLI {
    static func main() {
        do {
            try run()
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    static func run() throws {
        var arguments = Array(CommandLine.arguments.dropFirst())
        let command = arguments.first ?? "help"
        if !arguments.isEmpty { arguments.removeFirst() }
        let json = takeFlag("--json", from: &arguments)

        switch command {
        case "start":
            try start(arguments: arguments, json: json)
        case "stop":
            try stop(json: json)
        case "status":
            try status(json: json)
        case "apps":
            try requestResponse(action: .apps, json: json)
        case "doctor":
            try requestResponse(action: .doctor, json: json)
        case "setup":
            try requestResponse(action: .setup, json: json, timeout: 120)
        case "help", "--help", "-h":
            printHelp()
        case "--version", "-V":
            print("0.4.0")
        default:
            throw CaptureCoreError.message("Unknown command \"\(command)\". Run capture --help.")
        }
    }

    static func start(arguments: [String], json: Bool) throws {
        var arguments = arguments
        guard let app = takeOption("--app", from: &arguments) else {
            throw CaptureCoreError.message("Missing required --app APP. Run capture apps to list shareable apps.")
        }
        let output = takeOption("--output", from: &arguments)
        let width = try positiveInteger(takeOption("--width", from: &arguments), name: "Width")
        let height = try positiveInteger(takeOption("--height", from: &arguments), name: "Height")
        guard arguments.isEmpty else {
            throw CaptureCoreError.message("Unknown start argument: \(arguments[0])")
        }

        try CapturePaths.ensureControlDir()
        if var oldState = try? readJSON(CaptureState.self, from: CapturePaths.state), oldState.status.isActive {
            if processExists(oldState.pid) {
                throw CaptureCoreError.message("A capture is already active for \(oldState.appName ?? oldState.requestedApp).")
            }
            oldState.status = .failed
            oldState.error = "Capture agent exited without finalizing the recording."
            try writeJSON(oldState, to: CapturePaths.state)
        }

        let outputDir = try prepareOutputDirectory(output, app: app)
        let outputPath = outputDir.appendingPathComponent("recording.mp4")
        let metadataPath = outputDir.appendingPathComponent("metadata.json")
        let token = UUID().uuidString.lowercased()
        let requestURL = CapturePaths.request(token: token)
        let request = CaptureRequest(action: .start, token: token, app: app, outputDir: outputDir.path, width: width, height: height)
        let state = CaptureState(token: token, status: .starting, requestedApp: app, outputDir: outputDir.path, outputPath: outputPath.path, metadataPath: metadataPath.path)

        try? FileManager.default.removeItem(at: CapturePaths.stop)
        try writeJSON(request, to: requestURL)
        try writeJSON(state, to: CapturePaths.state)
        try launchAgent(requestPath: requestURL)

        let result = try waitForState(token: token, timeout: 60) { $0.status == .recording || $0.status == .failed }
        if result.status == .failed {
            throw CaptureCoreError.message(result.error ?? "Capture failed to start.")
        }
        printState(result, json: json)
    }

    static func stop(json: Bool) throws {
        guard var state = try? readJSON(CaptureState.self, from: CapturePaths.state), state.status.isActive else {
            throw CaptureCoreError.message("No capture is currently active.")
        }
        guard processExists(state.pid) else {
            state.status = .failed
            state.error = "Capture agent is no longer running."
            try writeJSON(state, to: CapturePaths.state)
            throw CaptureCoreError.message(state.error!)
        }

        try Data(state.token.utf8).write(to: CapturePaths.stop, options: [.atomic])
        let result = try waitForState(token: state.token, timeout: 30) { $0.status == .stopped || $0.status == .failed }
        if result.status == .failed {
            throw CaptureCoreError.message(result.error ?? "Capture failed while stopping.")
        }
        printState(result, json: json)
    }

    static func status(json: Bool) throws {
        guard var state = try? readJSON(CaptureState.self, from: CapturePaths.state) else {
            if json { printJSON(["active": false]) } else { print("Capture inactive.") }
            return
        }
        if state.status.isActive && !processExists(state.pid) {
            state.status = .failed
            state.error = "Capture agent exited without finalizing the recording."
            try writeJSON(state, to: CapturePaths.state)
        }
        printState(state, json: json)
    }

    static func requestResponse(action: CaptureAction, json: Bool, timeout: TimeInterval = 30) throws {
        try CapturePaths.ensureControlDir()
        let token = UUID().uuidString.lowercased()
        let requestURL = CapturePaths.request(token: token)
        let response = CapturePaths.response(token: token)
        try? FileManager.default.removeItem(at: response)
        let request = CaptureRequest(action: action, token: token, responsePath: response.path)
        try writeJSON(request, to: requestURL)
        try launchAgent(requestPath: requestURL)

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: response.path) {
                let data = try Data(contentsOf: response)
                if json { FileHandle.standardOutput.write(data) }
                else if let object = try? JSONSerialization.jsonObject(with: data),
                        let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
                        let string = String(data: pretty, encoding: .utf8) {
                    print(string)
                }
                try? FileManager.default.removeItem(at: response)
                try? FileManager.default.removeItem(at: requestURL)
                if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["ok"] as? Bool == false {
                    throw CaptureCoreError.message("capture \(action.rawValue) reported a failed check.")
                }
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw CaptureCoreError.message("Capture agent did not respond to \(action.rawValue).")
    }

    static func launchAgent(requestPath: URL) throws {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let app = executable.deletingLastPathComponent().appendingPathComponent("CaptureAgent.app")
        guard FileManager.default.fileExists(atPath: app.path) else {
            throw CaptureCoreError.message("CaptureAgent.app was not found beside the capture executable at \(app.path).")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-gj", "-n", app.path, "--args", "--request", requestPath.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CaptureCoreError.message("macOS could not launch CaptureAgent.app.")
        }
    }

    static func waitForState(token: String, timeout: TimeInterval, predicate: (CaptureState) -> Bool) throws -> CaptureState {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let state = try? readJSON(CaptureState.self, from: CapturePaths.state), state.token == token, predicate(state) {
                return state
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw CaptureCoreError.message("Timed out waiting for the capture agent.")
    }

    static func prepareOutputDirectory(_ output: String?, app: String) throws -> URL {
        let directory: URL
        if let output {
            directory = expandPath(output)
        } else {
            let safeApp = app.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            directory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Movies/capture", isDirectory: true)
                .appendingPathComponent("\(timestampForPath())-\(safeApp.isEmpty ? "app" : safeApp)", isDirectory: true)
        }

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw CaptureCoreError.message("Output exists and is not a directory: \(directory.path)") }
            let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            guard contents.isEmpty else { throw CaptureCoreError.message("Refusing to overwrite non-empty output directory: \(directory.path)") }
        } else {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    static func takeFlag(_ name: String, from arguments: inout [String]) -> Bool {
        guard let index = arguments.firstIndex(of: name) else { return false }
        arguments.remove(at: index)
        return true
    }

    static func takeOption(_ name: String, from arguments: inout [String]) -> String? {
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
        let value = arguments[index + 1]
        arguments.removeSubrange(index...index + 1)
        return value
    }

    static func positiveInteger(_ value: String?, name: String) throws -> Int? {
        guard let value else { return nil }
        guard let parsed = Int(value), parsed > 0 else { throw CaptureCoreError.message("\(name) must be a positive integer.") }
        return parsed
    }

    static func printState(_ state: CaptureState, json: Bool) {
        if json {
            printJSON(state)
        } else {
            print("Capture \(state.status.rawValue).")
            if let appName = state.appName { print("App: \(appName)") }
            print("Output: \(state.outputPath)")
            print("Metadata: \(state.metadataPath)")
            if let error = state.error { print("Error: \(error)") }
        }
    }

    static func printJSON<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(value) + Data([0x0a]) { FileHandle.standardOutput.write(data) }
    }

    static func printHelp() {
        print("""
        Usage: capture <command> [options]

          capture start --app APP [--output DIR] [--width PX] [--height PX] [--json]
          capture stop [--json]
          capture status [--json]
          capture apps [--json]
          capture doctor [--json]
          capture setup [--json]
        """)
    }
}
