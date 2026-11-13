import Foundation
import LiveCore
import XCTest

final class ProcessRunnerTests: XCTestCase {
    func testDrainsBothPipesBeforeWaitingForExit() {
        let result = runProcess(URL(fileURLWithPath: "/bin/sh"), ["-c", "/usr/bin/head -c 1048576 /dev/zero; /usr/bin/head -c 1048576 /dev/zero >&2; exit 42"], timeout: 5)
        XCTAssertEqual(result.status, 42)
        XCTAssertEqual(result.stdoutData.count, 1_048_576)
        XCTAssertEqual(result.stderr.utf8.count, 1_048_576)
    }

    func testTimeoutKillsAChildThatIgnoresTermination() {
        let started = ContinuousClock.now
        let result = runProcess(URL(fileURLWithPath: "/bin/sh"), ["-c", "trap '' TERM; while :; do :; done"], timeout: 0.1)
        XCTAssertEqual(result.status, 124)
        XCTAssertTrue(result.stderr.contains("timed out"))
        XCTAssertLessThan(started.duration(to: .now), .seconds(3))
    }

    func testLaunchFailureReturnsDiagnostic() {
        let result = runProcess(URL(fileURLWithPath: "/nonexistent-record-test-command"), [])
        XCTAssertEqual(result.status, 127)
        XCTAssertFalse(result.stderr.isEmpty)
    }
}
