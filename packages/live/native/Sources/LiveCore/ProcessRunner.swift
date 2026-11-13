import Darwin
import Foundation

public struct ProcessResult {
    public let status: Int32
    public let stdoutData: Data
    public let stderr: String
}

// Drain both pipes while the child runs. Waiting for exit first can deadlock
// when either pipe fills; waiting for EOF can hang on an inherited child pipe.
public func runProcess(_ executable: URL, _ arguments: [String], timeout: TimeInterval = 150) -> ProcessResult {
    let process = Process()
    let stdout = Pipe()
    let stderr = Pipe()
    process.executableURL = executable
    process.arguments = arguments
    process.standardOutput = stdout
    process.standardError = stderr
    var output = Data()
    var errors = Data()
    do {
        for handle in [stdout.fileHandleForReading, stderr.fileHandleForReading] {
            let flags = fcntl(handle.fileDescriptor, F_GETFL)
            guard flags >= 0, fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
                throw LiveError("could not configure subprocess output pipes")
            }
        }
        try process.run()
    } catch {
        return ProcessResult(status: 127, stdoutData: Data(), stderr: error.localizedDescription)
    }
    try? stdout.fileHandleForWriting.close()
    try? stderr.fileHandleForWriting.close()
    defer {
        try? stdout.fileHandleForReading.close()
        try? stderr.fileHandleForReading.close()
    }
    let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
    while process.isRunning && ContinuousClock.now < deadline {
        drain(stdout.fileHandleForReading, into: &output)
        drain(stderr.fileHandleForReading, into: &errors)
        Thread.sleep(forTimeInterval: 0.01)
    }
    let timedOut = process.isRunning
    if timedOut {
        process.terminate()
        let grace = ContinuousClock.now.advanced(by: .milliseconds(500))
        while process.isRunning && ContinuousClock.now < grace {
            drain(stdout.fileHandleForReading, into: &output)
            drain(stderr.fileHandleForReading, into: &errors)
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }
    // With the child gone, collect buffered output without waiting for any
    // descendants that may still hold the write ends open.
    drain(stdout.fileHandleForReading, into: &output)
    drain(stderr.fileHandleForReading, into: &errors)
    var message = String(data: errors, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if timedOut { message += "\nSubprocess timed out after \(timeout) seconds." }
    return ProcessResult(status: timedOut ? 124 : process.terminationStatus, stdoutData: output, stderr: message)
}

private func drain(_ handle: FileHandle, into data: inout Data) {
    var buffer = [UInt8](repeating: 0, count: 8192)
    // Bound each pass so a noisy child cannot starve the other pipe or timeout.
    for _ in 0..<128 {
        let count = Darwin.read(handle.fileDescriptor, &buffer, buffer.count)
        if count > 0 { data.append(contentsOf: buffer.prefix(count)) }
        else if count < 0 && errno == EINTR { continue }
        else { break }
    }
}
