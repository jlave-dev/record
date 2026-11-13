import Foundation
import LiveCore
import XCTest

final class EventLogReaderTests: XCTestCase {
    private func line(_ cursor: Int, text: String = "hello", type: String = "transcript.final") throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "schema_version": 1, "cursor": cursor, "type": type,
            "source_audio_ms": 0, "wall_elapsed_ms": 0, "delivery_latency_ms": 0,
            "created_at": "fixture", "text": text,
        ]) + Data([0x0a])
    }

    func testChunkBoundariesLongLinesAndIncompleteAppend() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let longText = String(repeating: "héllo", count: 30_000)
        let tail = try line(4)
        var data = try line(1) + line(2, text: longText) + line(3, type: "transcript.partial")
        data.append(tail.dropLast())
        try data.write(to: url)
        XCTAssertEqual(try EventLogReader.read(url: url, after: 0).map(\.cursor), [1, 2])
        XCTAssertEqual(try EventLogReader.read(url: url, after: 1).first?.text, longText)
        XCTAssertEqual(try EventLogReader.read(url: url, after: 2, includePartials: true).map(\.cursor), [3])
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0x0a]))
        try handle.close()
        XCTAssertEqual(try EventLogReader.read(url: url, after: 2).map(\.cursor), [4])
        XCTAssertTrue(try EventLogReader.read(url: url, after: 4).isEmpty)
        XCTAssertTrue(try EventLogReader.read(url: url, after: 99).isEmpty)
    }

    func testCaughtUpPollStopsBeforeDecodingOldHistory() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        // Deliberately undecodable history proves the reader stops at the cursor.
        try (Data("old history that must not be decoded\n".utf8) + line(50_000) + line(50_001)).write(to: url)
        XCTAssertEqual(try EventLogReader.read(url: url, after: 50_000).map(\.cursor), [50_001])
        XCTAssertThrowsError(try EventLogReader.read(url: url, after: 0))
    }

    func testMissingEmptyAndUnterminatedLogsReturnNoEvents() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(try EventLogReader.read(url: url, after: 0).isEmpty)
        try Data().write(to: url)
        XCTAssertTrue(try EventLogReader.read(url: url, after: 0).isEmpty)
        try Data(repeating: 0x7b, count: 200_000).write(to: url)
        XCTAssertTrue(try EventLogReader.read(url: url, after: 0).isEmpty)
    }
}
