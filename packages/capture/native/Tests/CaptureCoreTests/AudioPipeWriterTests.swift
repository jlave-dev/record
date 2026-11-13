import CaptureCore
import Foundation
import XCTest

final class AudioPipeWriterTests: XCTestCase {
    func testAStalledReaderFailsWithinTheDeadline() throws {
        let pipe = Pipe()
        let writer = try AudioPipeWriter(handle: pipe.fileHandleForWriting)
        let started = ContinuousClock.now
        XCTAssertThrowsError(try writer.write(Data(repeating: 0, count: 1_048_576), timeout: 0.1))
        XCTAssertLessThan(started.duration(to: .now), .seconds(2))
        try pipe.fileHandleForReading.close()
        try pipe.fileHandleForWriting.close()
    }

    func testExitedReaderReportsFailureInsteadOfHangingOrSignalling() throws {
        let pipe = Pipe()
        let writer = try AudioPipeWriter(handle: pipe.fileHandleForWriting)
        try pipe.fileHandleForReading.close()
        XCTAssertThrowsError(try writer.write(Data([1, 2, 3])))
        try pipe.fileHandleForWriting.close()
    }

    func testWritablePipePreservesBytes() throws {
        let pipe = Pipe()
        let writer = try AudioPipeWriter(handle: pipe.fileHandleForWriting)
        let bytes = Data([1, 2, 3, 4])
        try writer.write(bytes)
        try pipe.fileHandleForWriting.close()
        XCTAssertEqual(try pipe.fileHandleForReading.readToEnd(), bytes)
        try pipe.fileHandleForReading.close()
    }
}
