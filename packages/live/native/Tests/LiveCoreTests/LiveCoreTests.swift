import Foundation
import LiveCore
import XCTest

final class LiveCoreTests: XCTestCase {
    func testFrameRoundTripAndTruncation() throws {
        let frame = AudioFrame(sourceAudioMs: 640, samples: [0.25, -0.5, 1])
        let pipe = Pipe()
        try pipe.fileHandleForWriting.write(contentsOf: frame.encoded())
        try pipe.fileHandleForWriting.close()
        XCTAssertEqual(try AudioFrame.read(from: pipe.fileHandleForReading), frame)
        XCTAssertNil(try AudioFrame.read(from: pipe.fileHandleForReading))

        let truncated = Pipe()
        try truncated.fileHandleForWriting.write(contentsOf: frame.encoded().dropLast())
        try truncated.fileHandleForWriting.close()
        XCTAssertThrowsError(try AudioFrame.read(from: truncated.fileHandleForReading))
    }

    func testCommitPolicyReasons() {
        let stable = CommitPolicy(stablePartialMs: 100, maxUtteranceMs: 1_000)
        XCTAssertEqual(stable.updatePartial("hello", sourceAudioMs: 20, nowMs: 0)?.type, "transcript.partial")
        XCTAssertNil(stable.poll(sourceAudioMs: 80, nowMs: 99))
        XCTAssertEqual(stable.poll(sourceAudioMs: 120, nowMs: 100)?.finalReason, "stable_partial")

        let maximum = CommitPolicy(stablePartialMs: 1_000, maxUtteranceMs: 100)
        _ = maximum.updatePartial("long thought", sourceAudioMs: 20, nowMs: 0)
        XCTAssertEqual(maximum.poll(sourceAudioMs: 120, nowMs: 100)?.finalReason, "max_utterance")

        let native = CommitPolicy()
        XCTAssertEqual(native.nativeFinal("done", sourceAudioMs: 50)?.finalReason, "end_of_utterance")

        let end = CommitPolicy()
        _ = end.updatePartial("tail", sourceAudioMs: 50, nowMs: 0)
        XCTAssertEqual(end.finish(sourceAudioMs: 80)?.finalReason, "end_of_stream")
    }

    func testEventLogCursorAndPartialFiltering() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("events.jsonl")
        let writer = try EventLogWriter(url: url)
        _ = try writer.append(TranscriptEmission(type: "transcript.partial", sourceAudioMs: 10, text: "hel"))
        _ = try writer.append(TranscriptEmission(type: "transcript.final", sourceAudioMs: 20, text: "hello", finalReason: "stable_partial"))
        _ = try writer.appendSystem(type: "live.stopped", sourceAudioMs: 20)
        try writer.close()
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertEqual(try EventLogReader.read(url: url, after: 0).map(\.cursor), [2, 3])
        XCTAssertEqual(try EventLogReader.read(url: url, after: 2).map(\.type), ["live.stopped"])
        XCTAssertEqual(try EventLogReader.read(url: url, after: 0, includePartials: true).count, 3)
    }
}
