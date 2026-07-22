import Foundation

public let liveModelRelativePaths = [
    "streaming_encoder.mlmodelc/coremldata.bin",
    "decoder.mlmodelc/coremldata.bin",
    "joint_decision.mlmodelc/coremldata.bin",
    "vocab.json",
]

public func liveModelDirectory() -> URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appendingPathComponent("FluidAudio/Models/parakeet-eou-streaming/parakeet-eou-streaming/320ms", isDirectory: true)
}

public func liveModelsAreReady(in directory: URL) -> Bool {
    liveModelRelativePaths.allSatisfy {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
    }
}

public struct AudioFrame: Sendable, Equatable {
    public static let magic: UInt32 = 0x524C4956
    public static let version: UInt32 = 1
    public static let headerSize = 20

    public let sourceAudioMs: Int64
    public let samples: [Float]

    public init(sourceAudioMs: Int64, samples: [Float]) {
        self.sourceAudioMs = sourceAudioMs
        self.samples = samples
    }

    public func encoded() -> Data {
        var data = Data(capacity: Self.headerSize + samples.count * MemoryLayout<Float>.size)
        data.appendLittleEndian(Self.magic)
        data.appendLittleEndian(Self.version)
        data.appendLittleEndian(sourceAudioMs)
        data.appendLittleEndian(UInt32(samples.count))
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    public static func read(from handle: FileHandle) throws -> AudioFrame? {
        guard let header = try handle.readExactly(Self.headerSize) else { return nil }
        var offset = 0
        let magic: UInt32 = try header.readLittleEndian(at: &offset)
        let version: UInt32 = try header.readLittleEndian(at: &offset)
        let sourceAudioMs: Int64 = try header.readLittleEndian(at: &offset)
        let sampleCount: UInt32 = try header.readLittleEndian(at: &offset)
        guard magic == Self.magic else { throw LiveError("invalid audio frame magic") }
        guard version == Self.version else { throw LiveError("unsupported audio frame version \(version)") }
        guard sampleCount <= 160_000 else { throw LiveError("audio frame is too large") }
        guard let payload = try handle.readExactly(Int(sampleCount) * MemoryLayout<Float>.size) else {
            throw LiveError("truncated audio frame payload")
        }
        var samples = [Float](repeating: 0, count: Int(sampleCount))
        _ = samples.withUnsafeMutableBytes { destination in
            payload.copyBytes(to: destination)
        }
        return AudioFrame(sourceAudioMs: sourceAudioMs, samples: samples)
    }
}

public struct TranscriptEmission: Sendable, Equatable {
    public let type: String
    public let sourceAudioMs: Int
    public let text: String
    public let finalReason: String?

    public init(type: String, sourceAudioMs: Int, text: String, finalReason: String? = nil) {
        self.type = type
        self.sourceAudioMs = sourceAudioMs
        self.text = text
        self.finalReason = finalReason
    }
}

public final class CommitPolicy: @unchecked Sendable {
    private let lock = NSLock()
    private let stablePartialMs: Int
    private let maxUtteranceMs: Int
    private var lastPartial = ""
    private var lastPartialChangedAtMs = 0
    private var utteranceStartedAtMs = 0
    private var sourceAudioMs = 0

    public init(stablePartialMs: Int = 1500, maxUtteranceMs: Int = 15_000) {
        self.stablePartialMs = stablePartialMs
        self.maxUtteranceMs = maxUtteranceMs
    }

    public func updatePartial(_ text: String, sourceAudioMs: Int, nowMs: Int) -> TranscriptEmission? {
        let text = normalize(text)
        guard !text.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        self.sourceAudioMs = sourceAudioMs
        guard text != lastPartial else { return nil }
        if lastPartial.isEmpty { utteranceStartedAtMs = nowMs }
        lastPartial = text
        lastPartialChangedAtMs = nowMs
        return TranscriptEmission(type: "transcript.partial", sourceAudioMs: sourceAudioMs, text: text)
    }

    public func poll(sourceAudioMs: Int, nowMs: Int) -> TranscriptEmission? {
        lock.lock()
        defer { lock.unlock() }
        self.sourceAudioMs = sourceAudioMs
        guard !lastPartial.isEmpty else { return nil }
        if nowMs - lastPartialChangedAtMs >= stablePartialMs {
            return commitLocked(lastPartial, reason: "stable_partial")
        }
        if nowMs - utteranceStartedAtMs >= maxUtteranceMs {
            return commitLocked(lastPartial, reason: "max_utterance")
        }
        return nil
    }

    public func nativeFinal(_ text: String, sourceAudioMs: Int) -> TranscriptEmission? {
        let text = normalize(text)
        guard !text.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        self.sourceAudioMs = sourceAudioMs
        return commitLocked(text, reason: "end_of_utterance")
    }

    public func finish(_ text: String = "", sourceAudioMs: Int) -> TranscriptEmission? {
        lock.lock()
        defer { lock.unlock() }
        self.sourceAudioMs = sourceAudioMs
        let text = normalize(text).isEmpty ? lastPartial : normalize(text)
        guard !text.isEmpty else { return nil }
        return commitLocked(text, reason: "end_of_stream")
    }

    private func commitLocked(_ text: String, reason: String) -> TranscriptEmission {
        lastPartial = ""
        lastPartialChangedAtMs = 0
        utteranceStartedAtMs = 0
        return TranscriptEmission(
            type: "transcript.final",
            sourceAudioMs: sourceAudioMs,
            text: text,
            finalReason: reason
        )
    }
}

public struct TranscriptEvent: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let cursor: Int
    public let type: String
    public let sourceAudioMs: Int
    public let wallElapsedMs: Int
    public let deliveryLatencyMs: Int
    public let createdAt: String
    public let text: String
    public let finalReason: String?
}

public final class EventLogWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private let clock = ContinuousClock()
    private let started: ContinuousClock.Instant
    private let timestampFormatter: ISO8601DateFormatter
    private var cursor = 0
    private var closed = false

    public init(url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            throw LiveError("refusing existing transcript event file: \(url.path)")
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
            throw LiveError("could not create transcript event file: \(url.path)")
        }
        handle = try FileHandle(forWritingTo: url)
        started = clock.now
        timestampFormatter = ISO8601DateFormatter()
        timestampFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    @discardableResult
    public func append(_ emission: TranscriptEmission) throws -> TranscriptEvent {
        try append(
            type: emission.type,
            sourceAudioMs: emission.sourceAudioMs,
            text: emission.text,
            finalReason: emission.finalReason
        )
    }

    @discardableResult
    public func appendSystem(type: String, sourceAudioMs: Int, text: String = "") throws -> TranscriptEvent {
        try append(type: type, sourceAudioMs: sourceAudioMs, text: text, finalReason: nil)
    }

    public func close() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        try handle.synchronize()
        try handle.close()
    }

    private func append(type: String, sourceAudioMs: Int, text: String, finalReason: String?) throws -> TranscriptEvent {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { throw LiveError("transcript event log is closed") }
        cursor += 1
        let wallMs = elapsedMilliseconds(started.duration(to: clock.now))
        let event = TranscriptEvent(
            schemaVersion: 1,
            cursor: cursor,
            type: type,
            sourceAudioMs: sourceAudioMs,
            wallElapsedMs: wallMs,
            deliveryLatencyMs: max(0, wallMs - sourceAudioMs),
            createdAt: timestampFormatter.string(from: Date()),
            text: text,
            finalReason: finalReason
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        try handle.write(contentsOf: encoder.encode(event) + Data([0x0a]))
        if type != "transcript.partial" { try handle.synchronize() }
        return event
    }
}

public enum EventLogReader {
    public static func read(url: URL, after cursor: Int, includePartials: Bool = false) throws -> [TranscriptEvent] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .map { try decoder.decode(TranscriptEvent.self, from: Data($0.utf8)) }
            .filter { $0.cursor > cursor && (includePartials || $0.type != "transcript.partial") }
    }
}

public struct LiveError: Error, LocalizedError, Sendable {
    public let message: String

    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

private func normalize(_ text: String) -> String {
    text.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
}

private func elapsedMilliseconds(_ duration: Duration) -> Int {
    let components = duration.components
    return Int(Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15)
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }

    func readLittleEndian<T: FixedWidthInteger>(at offset: inout Int) throws -> T {
        let size = MemoryLayout<T>.size
        guard offset + size <= count else { throw LiveError("truncated audio frame header") }
        let value = self[offset..<(offset + size)].withUnsafeBytes { $0.loadUnaligned(as: T.self) }
        offset += size
        return T(littleEndian: value)
    }
}

private extension FileHandle {
    func readExactly(_ count: Int) throws -> Data? {
        var data = Data()
        while data.count < count {
            guard let chunk = try read(upToCount: count - data.count), !chunk.isEmpty else {
                if data.isEmpty { return nil }
                throw LiveError("truncated audio frame")
            }
            data.append(chunk)
        }
        return data
    }
}
