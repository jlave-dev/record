import ABSupport
import AVFoundation
import FluidAudio
import Foundation

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
        guard options.locale.language.languageCode?.identifier == "en" else {
            throw CLIError("FluidAudio Parakeet EOU currently supports English; use --locale en-US")
        }

        let manager = StreamingEouAsrManager(chunkSize: .ms320, eouDebounceMs: 1280)
        try await manager.loadModels()

        if let eventsURL = options.replayEvents {
            try await replay(options, manager: manager, eventsURL: eventsURL)
            return
        }

        let audioFile = try AVAudioFile(forReading: options.input)
        let frameCount = AVAudioFrameCount(audioFile.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: frameCount) else {
            throw CLIError("could not allocate audio buffer")
        }
        try audioFile.read(into: buffer)

        let clock = ContinuousClock()
        let started = clock.now
        await manager.reset()
        var transcript = try await manager.process(audioBuffer: buffer)
        transcript += try await manager.finish()
        let processingSeconds = seconds(started.duration(to: clock.now))
        let eouTimestamps = await manager.getEouTimestampsMs()

        let result = TranscriptResult(
            engine: "fluidaudio-parakeet-eou",
            model: "FluidAudio 0.15.5 / Parakeet EOU 120M 320ms",
            locale: options.locale.identifier,
            inputFile: options.input.lastPathComponent,
            audioDurationSeconds: try audioDurationSeconds(options.input),
            processingSeconds: processingSeconds,
            transcript: transcript.split(whereSeparator: \Character.isWhitespace).joined(separator: " "),
            segments: [],
            endOfUtteranceTimestampsMs: eouTimestamps
        )
        try writeResult(result, to: options.output)
    }

    private static func replay(
        _ options: CLIOptions,
        manager: StreamingEouAsrManager,
        eventsURL: URL
    ) async throws {
        let writer = try ReplayEventWriter(url: eventsURL)
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

        let processingSeconds = seconds(started.duration(to: clock.now))
        let result = TranscriptResult(
            engine: "fluidaudio-parakeet-eou-replay",
            model: "FluidAudio 0.15.5 / Parakeet EOU 120M 320ms",
            locale: options.locale.identifier,
            inputFile: options.input.lastPathComponent,
            audioDurationSeconds: try audioDurationSeconds(options.input),
            processingSeconds: processingSeconds,
            transcript: writer.committedTranscript,
            segments: []
        )
        try writeResult(result, to: options.output)
    }

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
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
    private var committed: [String] = []
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

    var committedTranscript: String {
        lock.lock()
        defer { lock.unlock() }
        return committed.joined(separator: " ")
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
        committed.append(normalized)
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
