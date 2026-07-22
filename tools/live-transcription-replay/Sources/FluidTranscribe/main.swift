import AVFoundation
import FluidAudio
import Foundation

private struct CLIOptions: Sendable {
    let input: URL
    let events: URL
    let stablePartialMs: Int
    let maxUtteranceMs: Int

    static func parse(_ arguments: [String]) throws -> CLIOptions {
        var input: String?
        var events: String?
        var stablePartialMs = 1500
        var maxUtteranceMs = 15_000
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            if argument == "-h" || argument == "--help" {
                throw CLIError(
                    "usage: fluid-transcribe --input canonical.wav --events events.jsonl [--stable-partial-ms 1500] [--max-utterance-ms 15000]",
                    exitCode: 0
                )
            }
            index += 1
            guard index < arguments.count else { throw CLIError("\(argument) requires a value") }
            let value = arguments[index]
            switch argument {
            case "--input": input = value
            case "--events": events = value
            case "--stable-partial-ms":
                guard let parsed = Int(value), parsed > 0 else {
                    throw CLIError("--stable-partial-ms requires a positive integer")
                }
                stablePartialMs = parsed
            case "--max-utterance-ms":
                guard let parsed = Int(value), parsed > 0 else {
                    throw CLIError("--max-utterance-ms requires a positive integer")
                }
                maxUtteranceMs = parsed
            default: throw CLIError("unknown argument: \(argument)")
            }
            index += 1
        }

        guard let input, let events else {
            throw CLIError("--input and --events are required")
        }
        let inputURL = URL(fileURLWithPath: input).standardizedFileURL
        guard FileManager.default.isReadableFile(atPath: inputURL.path) else {
            throw CLIError("input is not readable: \(inputURL.path)")
        }
        let eventsURL = URL(fileURLWithPath: events).standardizedFileURL

        return CLIOptions(
            input: inputURL,
            events: eventsURL,
            stablePartialMs: stablePartialMs,
            maxUtteranceMs: maxUtteranceMs
        )
    }
}

private struct CLIError: Error {
    let message: String
    let exitCode: Int32

    init(_ message: String, exitCode: Int32 = 2) {
        self.message = message
        self.exitCode = exitCode
    }
}

@main
struct FluidTranscribe {
    static func main() async {
        do {
            let options = try CLIOptions.parse(Array(CommandLine.arguments.dropFirst()))
            try await transcribe(options)
        } catch let error as CLIError {
            FileHandle.standardError.write(Data("\(error.message)\n".utf8))
            exit(error.exitCode)
        } catch {
            FileHandle.standardError.write(Data("FluidAudio transcription failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func transcribe(_ options: CLIOptions) async throws {
        let manager = StreamingEouAsrManager(chunkSize: .ms320, eouDebounceMs: 1280)
        try await manager.loadModels()
        try await replay(options, manager: manager)
    }

    private static func replay(
        _ options: CLIOptions,
        manager: StreamingEouAsrManager
    ) async throws {
        let writer = try ReplayEventWriter(url: options.events)
        await manager.setPartialCallback { writer.partial($0) }
        await manager.setEouCallback { writer.final($0, reason: "end_of_utterance") }
        await manager.reset()

        let audioFile = try AVAudioFile(forReading: options.input)
        let sampleRate = audioFile.processingFormat.sampleRate
        let replayFrames = AVAudioFrameCount((sampleRate * 0.32).rounded())
        let clock = ContinuousClock()
        let started = clock.now
        var framesRead: AVAudioFramePosition = 0

        while audioFile.framePosition < audioFile.length {
            let remaining = audioFile.length - audioFile.framePosition
            let capacity = AVAudioFrameCount(min(AVAudioFramePosition(replayFrames), remaining))
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: audioFile.processingFormat,
                frameCapacity: capacity
            ) else {
                throw CLIError("could not allocate replay audio buffer")
            }
            try audioFile.read(into: buffer)
            guard buffer.frameLength > 0 else { break }

            framesRead += AVAudioFramePosition(buffer.frameLength)
            let sourceAudioMs = Int((Double(framesRead) * 1000 / sampleRate).rounded())
            let target = started.advanced(by: .milliseconds(sourceAudioMs))
            if clock.now < target {
                try await clock.sleep(until: target)
            }

            writer.setSourceAudioMs(sourceAudioMs)
            _ = try await manager.process(audioBuffer: buffer)
            try writer.checkError()

            if await manager.eouDetected {
                // ponytail: reset per committed utterance until FluidAudio supports repeated EOU callbacks in one session.
                await manager.reset()
            } else if let fallback = writer.fallbackCommit(
                stableAfterMs: options.stablePartialMs,
                maxAfterMs: options.maxUtteranceMs
            ) {
                writer.final(fallback.text, reason: fallback.reason)
                await manager.reset()
            }
        }

        let tail = try await manager.finish()
        if !(await manager.eouDetected) {
            writer.final(tail, reason: "end_of_stream")
        }
        try writer.close()
    }
}

private struct ReplayEvent: Encodable {
    let schemaVersion = 1
    let cursor: Int
    let type: String
    let sourceAudioMs: Int
    let wallElapsedMs: Int
    let deliveryLatencyMs: Int
    let createdAt: String
    let text: String
    let finalReason: String?
}

private final class ReplayEventWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private let timestampFormatter: ISO8601DateFormatter
    private let started = ContinuousClock().now
    private var cursor = 0
    private var sourceAudioMs = 0
    private var utteranceStartAudioMs = 0
    private var lastPartialAudioMs = 0
    private var lastPartial = ""
    private var errorMessage: String?
    private var isClosed = false

    init(url: URL) throws {
        let timestampFormatter = ISO8601DateFormatter()
        timestampFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.timestampFormatter = timestampFormatter
        if FileManager.default.fileExists(atPath: url.path) {
            throw CLIError("refusing existing replay event file: \(url.path)")
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard FileManager.default.createFile(
            atPath: url.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CLIError("could not create replay event file: \(url.path)")
        }
        handle = try FileHandle(forWritingTo: url)
    }

    func setSourceAudioMs(_ value: Int) {
        lock.lock()
        sourceAudioMs = value
        lock.unlock()
    }

    func partial(_ text: String) {
        let normalized = normalize(text)
        guard !normalized.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard normalized != lastPartial else { return }
        lastPartial = normalized
        lastPartialAudioMs = sourceAudioMs
        append(type: "transcript.partial", text: normalized, finalReason: nil)
    }

    func fallbackCommit(stableAfterMs: Int, maxAfterMs: Int) -> (text: String, reason: String)? {
        lock.lock()
        defer { lock.unlock() }
        guard !lastPartial.isEmpty else { return nil }
        if sourceAudioMs - lastPartialAudioMs >= stableAfterMs {
            return (lastPartial, "stable_partial")
        }
        if sourceAudioMs - utteranceStartAudioMs >= maxAfterMs {
            return (lastPartial, "max_utterance")
        }
        return nil
    }

    func final(_ text: String, reason: String) {
        let normalized = normalize(text)
        guard !normalized.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        lastPartial = ""
        utteranceStartAudioMs = sourceAudioMs
        lastPartialAudioMs = sourceAudioMs
        append(type: "transcript.final", text: normalized, finalReason: reason, flush: true)
    }

    func checkError() throws {
        lock.lock()
        defer { lock.unlock() }
        if let errorMessage {
            throw CLIError("could not write replay events: \(errorMessage)")
        }
    }

    func close() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        isClosed = true
        try handle.synchronize()
        try handle.close()
        if let errorMessage {
            throw CLIError("could not write replay events: \(errorMessage)")
        }
    }

    private func append(type: String, text: String, finalReason: String?, flush: Bool = false) {
        guard errorMessage == nil else { return }
        cursor += 1
        let wallMs = elapsedMilliseconds(started.duration(to: ContinuousClock().now))
        let event = ReplayEvent(
            cursor: cursor,
            type: type,
            sourceAudioMs: sourceAudioMs,
            wallElapsedMs: wallMs,
            deliveryLatencyMs: max(0, wallMs - sourceAudioMs),
            createdAt: timestampFormatter.string(from: Date()),
            text: text,
            finalReason: finalReason
        )
        do {
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            try handle.write(contentsOf: encoder.encode(event) + Data([0x0a]))
            if flush { try handle.synchronize() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func normalize(_ text: String) -> String {
        text.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
    }

    private func elapsedMilliseconds(_ duration: Duration) -> Int {
        let components = duration.components
        return Int(Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15)
    }
}
