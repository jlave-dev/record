import AVFoundation
import Foundation

public struct TranscriptSegment: Codable, Sendable {
    public let startMs: Int
    public let endMs: Int
    public let text: String

    public init(startMs: Int, endMs: Int, text: String) {
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
    }
}

public struct TranscriptResult: Codable, Sendable {
    public let schemaVersion: Int
    public let engine: String
    public let model: String
    public let locale: String
    public let inputFile: String
    public let audioDurationSeconds: Double
    public let processingSeconds: Double
    public let transcript: String
    public let segments: [TranscriptSegment]
    public let endOfUtteranceTimestampsMs: [Int]?

    public init(
        engine: String,
        model: String,
        locale: String,
        inputFile: String,
        audioDurationSeconds: Double,
        processingSeconds: Double,
        transcript: String,
        segments: [TranscriptSegment],
        endOfUtteranceTimestampsMs: [Int]? = nil
    ) {
        self.schemaVersion = 1
        self.engine = engine
        self.model = model
        self.locale = locale
        self.inputFile = inputFile
        self.audioDurationSeconds = audioDurationSeconds
        self.processingSeconds = processingSeconds
        self.transcript = transcript
        self.segments = segments
        self.endOfUtteranceTimestampsMs = endOfUtteranceTimestampsMs
    }
}

public struct CLIOptions: Sendable {
    public let input: URL
    public let output: URL
    public let locale: Locale
    public let replayEvents: URL?
    public let stablePartialMs: Int
    public let maxUtteranceMs: Int

    public static func parse(_ arguments: [String]) throws -> CLIOptions {
        var input: String?
        var output: String?
        var locale = "en-US"
        var replayEvents: String?
        var stablePartialMs = 1500
        var maxUtteranceMs = 15_000
        var index = 0

        while index < arguments.count {
            switch arguments[index] {
            case "--input":
                index += 1
                guard index < arguments.count else { throw CLIError("--input requires a path") }
                input = arguments[index]
            case "--output":
                index += 1
                guard index < arguments.count else { throw CLIError("--output requires a path") }
                output = arguments[index]
            case "--locale":
                index += 1
                guard index < arguments.count else { throw CLIError("--locale requires an identifier") }
                locale = arguments[index]
            case "--replay-events":
                index += 1
                guard index < arguments.count else { throw CLIError("--replay-events requires a path") }
                replayEvents = arguments[index]
            case "--stable-partial-ms":
                index += 1
                guard index < arguments.count, let value = Int(arguments[index]), value > 0 else {
                    throw CLIError("--stable-partial-ms requires a positive integer")
                }
                stablePartialMs = value
            case "--max-utterance-ms":
                index += 1
                guard index < arguments.count, let value = Int(arguments[index]), value > 0 else {
                    throw CLIError("--max-utterance-ms requires a positive integer")
                }
                maxUtteranceMs = value
            case "-h", "--help":
                throw CLIError(
                    "usage: ENGINE --input canonical.wav --output result.json [--locale en-US] [--replay-events events.jsonl] [--stable-partial-ms 1500] [--max-utterance-ms 15000]",
                    exitCode: 0
                )
            default:
                throw CLIError("unknown argument: \(arguments[index])")
            }
            index += 1
        }

        guard let input, let output else {
            throw CLIError(
                "usage: ENGINE --input canonical.wav --output result.json [--locale en-US] [--replay-events events.jsonl] [--stable-partial-ms 1500] [--max-utterance-ms 15000]"
            )
        }

        let inputURL = URL(fileURLWithPath: input).standardizedFileURL
        guard FileManager.default.isReadableFile(atPath: inputURL.path) else {
            throw CLIError("input is not readable: \(inputURL.path)")
        }

        return CLIOptions(
            input: inputURL,
            output: URL(fileURLWithPath: output).standardizedFileURL,
            locale: Locale(identifier: locale),
            replayEvents: replayEvents.map { URL(fileURLWithPath: $0).standardizedFileURL },
            stablePartialMs: stablePartialMs,
            maxUtteranceMs: maxUtteranceMs
        )
    }
}

public struct CLIError: Error, LocalizedError {
    public let message: String
    public let exitCode: Int32

    public init(_ message: String, exitCode: Int32 = 2) {
        self.message = message
        self.exitCode = exitCode
    }

    public var errorDescription: String? { message }
}

public func audioDurationSeconds(_ url: URL) throws -> Double {
    let file = try AVAudioFile(forReading: url)
    return Double(file.length) / file.processingFormat.sampleRate
}

public func writeResult(_ result: TranscriptResult, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(result) + Data([0x0a])
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    try data.write(to: url, options: [.atomic])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

public func normalizedTranscript(_ segments: [TranscriptSegment]) -> String {
    segments
        .sorted { ($0.startMs, $0.endMs) < ($1.startMs, $1.endMs) }
        .map(\.text)
        .joined(separator: " ")
        .split(whereSeparator: \Character.isWhitespace)
        .joined(separator: " ")
}
