import AVFoundation
import FluidAudio
import Foundation
import LiveCore

@main
struct LiveWorker {
    static func main() async {
        do {
            var arguments = Array(CommandLine.arguments.dropFirst())
            let command = arguments.isEmpty ? "help" : arguments.removeFirst()
            switch command {
            case "stream":
                try await stream(arguments)
            case "setup", "doctor":
                let manager = StreamingEouAsrManager(chunkSize: .ms320, eouDebounceMs: 1280)
                try await manager.loadModels()
                print("{\"ok\":true}")
            case "help", "--help", "-h":
                printHelp()
            default:
                throw LiveError("unknown live-worker command: \(command)")
            }
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func stream(_ arguments: [String]) async throws {
        var arguments = arguments
        guard let eventsPath = takeOption("--events", from: &arguments),
              let readyPath = takeOption("--ready", from: &arguments) else {
            throw LiveError("stream requires --events PATH and --ready PATH")
        }
        let stableMs = try positiveInteger(takeOption("--stable-partial-ms", from: &arguments), default: 1500)
        let maximumMs = try positiveInteger(takeOption("--max-utterance-ms", from: &arguments), default: 15_000)
        guard arguments.isEmpty else { throw LiveError("unknown stream argument: \(arguments[0])") }

        let manager = StreamingEouAsrManager(chunkSize: .ms320, eouDebounceMs: 1280)
        try await manager.loadModels()
        let writer = try EventLogWriter(url: URL(fileURLWithPath: eventsPath))
        let policy = CommitPolicy(stablePartialMs: stableMs, maxUtteranceMs: maximumMs)
        let context = WorkerContext()
        let clock = ContinuousClock()
        let started = clock.now

        await manager.setPartialCallback { text in
            if let emission = policy.updatePartial(
                text,
                sourceAudioMs: context.sourceAudioMs,
                nowMs: elapsedMilliseconds(started.duration(to: clock.now))
            ) {
                context.record { try writer.append(emission) }
            }
        }
        await manager.setEouCallback { text in
            if let emission = policy.nativeFinal(text, sourceAudioMs: context.sourceAudioMs) {
                context.record { try writer.append(emission) }
            }
        }
        await manager.reset()

        let readyURL = URL(fileURLWithPath: readyPath)
        try Data("ready\n".utf8).write(to: readyURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: readyURL.path)
        try writer.appendSystem(type: "live.started", sourceAudioMs: 0)

        while let frame = try AudioFrame.read(from: .standardInput) {
            context.sourceAudioMs = Int(frame.sourceAudioMs)
            let buffer = try audioBuffer(samples: frame.samples)
            _ = try await manager.process(audioBuffer: buffer)
            try context.checkError()

            if await manager.eouDetected {
                await manager.reset()
            } else if let emission = policy.poll(
                sourceAudioMs: context.sourceAudioMs,
                nowMs: elapsedMilliseconds(started.duration(to: clock.now))
            ) {
                try writer.append(emission)
                await manager.reset()
            }
        }

        let tail = try await manager.finish()
        if !(await manager.eouDetected), let emission = policy.finish(tail, sourceAudioMs: context.sourceAudioMs) {
            try writer.append(emission)
        }
        try context.checkError()
        try writer.appendSystem(type: "live.stopped", sourceAudioMs: context.sourceAudioMs)
        try writer.close()
    }

    private static func audioBuffer(samples: [Float]) throws -> AVAudioPCMBuffer {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ), let channel = buffer.floatChannelData?[0] else {
            throw LiveError("could not allocate worker audio buffer")
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            channel.update(from: source.baseAddress!, count: samples.count)
        }
        return buffer
    }

    private static func takeOption(_ name: String, from arguments: inout [String]) -> String? {
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
        let value = arguments[index + 1]
        arguments.removeSubrange(index...index + 1)
        return value
    }

    private static func positiveInteger(_ value: String?, default defaultValue: Int) throws -> Int {
        guard let value else { return defaultValue }
        guard let parsed = Int(value), parsed > 0 else { throw LiveError("timing values must be positive integers") }
        return parsed
    }

    private static func printHelp() {
        print("""
        Usage: live-worker <command>

          live-worker stream --events PATH --ready PATH
          live-worker setup
          live-worker doctor
        """)
    }
}

private final class WorkerContext: @unchecked Sendable {
    private let lock = NSLock()
    private var storedSourceAudioMs = 0
    private var storedError: Error?

    var sourceAudioMs: Int {
        get { lock.withLock { storedSourceAudioMs } }
        set { lock.withLock { storedSourceAudioMs = newValue } }
    }

    func record(_ operation: () throws -> Void) {
        lock.withLock {
            guard storedError == nil else { return }
            do { try operation() } catch { storedError = error }
        }
    }

    func checkError() throws {
        if let error = lock.withLock({ storedError }) { throw error }
    }
}

private func elapsedMilliseconds(_ duration: Duration) -> Int {
    let components = duration.components
    return Int(Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15)
}
