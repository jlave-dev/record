import CaptureCore
import CoreGraphics
import XCTest
@testable import CaptureCLI

final class CaptureCoreTests: XCTestCase {
    func testResolvesFriendlyAppNameAndPreservesAspectRatio() throws {
        let apps = [
            AppDescriptor(name: "Google Chrome", bundleID: "com.google.Chrome", processID: 10),
            AppDescriptor(name: "QuickTime Player", bundleID: "com.apple.QuickTimePlayerX", processID: 20)
        ]

        XCTAssertEqual(resolveApp("chrome", from: apps)?.bundleID, "com.google.Chrome")
        XCTAssertEqual(resolveApp("com.apple.QuickTimePlayerX", from: apps)?.name, "QuickTime Player")
        let dimensions = try recordingDimensions(sourceWidth: 1920, sourceHeight: 1080, requestedWidth: 1280, requestedHeight: nil)
        XCTAssertEqual(dimensions.width, 1280)
        XCTAssertEqual(dimensions.height, 720)
    }

    func testFindsNonPrimaryZoomShareDisplayAndLocalRect() {
        let displays = [
            CGRect(x: 0, y: 0, width: 1710, height: 1107),
            CGRect(x: 1710, y: 0, width: 1920, height: 1080)
        ]
        let shareFrame = CGRect(x: 1710, y: 34, width: 1920, height: 1046)

        let index = bestOverlappingDisplayIndex(for: shareFrame, displayFrames: displays)

        XCTAssertEqual(index, 1)
        XCTAssertEqual(localCaptureRect(for: shareFrame, in: displays[index!]), CGRect(x: 0, y: 34, width: 1920, height: 1046))
        XCTAssertEqual(bestMatchingWindowIndex(for: shareFrame, windowFrames: [CGRect(x: 100, y: 100, width: 800, height: 600), shareFrame]), 1)
        XCTAssertTrue(isZoomWindowShareMarker(CGRect(x: 1720, y: 45, width: 66, height: 20), inside: shareFrame))
        XCTAssertTrue(isZoomWindowShareMarker(CGRect(x: 1720, y: 45, width: 66, height: 20), inside: CGRect(x: 1710, y: 0, width: 1920, height: 1080)))
        XCTAssertFalse(isZoomWindowShareMarker(CGRect(x: 2500, y: 45, width: 66, height: 20), inside: shareFrame))
    }

    func testWaitsForCaptureAgentToExit() {
        var checks = 0

        XCTAssertTrue(waitForProcessExit(42, timeout: 1, pollInterval: 0) { _ in
            checks += 1
            return checks < 3
        })
        XCTAssertEqual(checks, 3)
        XCTAssertFalse(waitForProcessExit(42, timeout: 0, pollInterval: 0) { _ in true })
    }
}

final class CaptureLockTests: XCTestCase {
    func testConcurrentReservationIsRejectedAndReleaseAllowsRetry() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("session.lock")
        let first = try CaptureLock(url: url)
        XCTAssertThrowsError(try CaptureLock(url: url))
        first.release()
        let retry = try CaptureLock(url: url)
        XCTAssertThrowsError(try CaptureLock(url: url))
        retry.release()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testStartupLockRemainsHeldDuringAgentHandoff() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let commandURL = directory.appendingPathComponent("command.lock")
        let sessionURL = directory.appendingPathComponent("session.lock")
        let command = try CaptureLock(url: commandURL)
        let reservation = try CaptureLock(url: sessionURL)
        reservation.release()
        XCTAssertThrowsError(try CaptureLock(url: commandURL))
        let agent = try CaptureLock(url: sessionURL)
        command.release()
        let nextCommand = try CaptureLock(url: commandURL)
        XCTAssertThrowsError(try CaptureLock(url: sessionURL))
        nextCommand.release()
        agent.release()
    }

    func testScopeExitReleasesLockWithoutDeletingItsFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let lock = try CaptureLock(url: url)
            try withExtendedLifetime(lock) { XCTAssertThrowsError(try CaptureLock(url: url)) }
        }
        let retry = try CaptureLock(url: url)
        retry.release()
    }
}

final class CaptureHandoffTests: XCTestCase {
    func testDeadStarterIsNotMarkedFailedWhileAgentOwnsSession() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stateURL = directory.appendingPathComponent("state.json")
        let lockURL = directory.appendingPathComponent("session.lock")
        var state = CaptureState(token: "token", status: .starting, requestedApp: "app", outputDir: directory.path, outputPath: "output", metadataPath: "metadata")
        state.pid = 123
        try writeJSON(state, to: stateURL)
        let agent = try CaptureLock(url: lockURL)
        let duringHandoff = try markAbandonedCapture(stateURL: stateURL, lockURL: lockURL, message: "abandoned") { _ in false }
        XCTAssertEqual(duringHandoff?.status, .starting)
        XCTAssertEqual(try readJSON(CaptureState.self, from: stateURL).status, .starting)
        agent.release()
        let abandoned = try markAbandonedCapture(stateURL: stateURL, lockURL: lockURL, message: "abandoned") { _ in false }
        XCTAssertEqual(abandoned?.status, .failed)
        XCTAssertEqual(abandoned?.error, "abandoned")
    }

    func testRechecksStateAfterAcquiringSessionLock() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stateURL = directory.appendingPathComponent("state.json")
        let lockURL = directory.appendingPathComponent("session.lock")
        var state = CaptureState(token: "token", status: .starting, requestedApp: "app", outputDir: directory.path, outputPath: "output", metadataPath: "metadata")
        state.pid = 123
        try writeJSON(state, to: stateURL)
        let result = try markAbandonedCapture(stateURL: stateURL, lockURL: lockURL, message: "abandoned") { pid in
            if pid == 123 {
                state.pid = 456
                try! writeJSON(state, to: stateURL)
                return false
            }
            return pid == 456
        }
        XCTAssertEqual(result?.status, .starting)
        XCTAssertEqual(result?.pid, 456)
        XCTAssertEqual(try readJSON(CaptureState.self, from: stateURL).status, .starting)
    }

}

final class CaptureStartupWaitTests: XCTestCase {
    func testCommandLockIsReleasedOnlyAfterAgentTakesOver() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let lockURL = directory.appendingPathComponent("command.lock")
        let lock = try CaptureLock(url: lockURL)
        var state = CaptureState(token: "token", status: .starting, requestedApp: "app", outputDir: directory.path, outputPath: "output", metadataPath: "metadata")
        var reads = 0
        let result = try CaptureCLI.waitForStart(token: "token", starterPID: 123, commandLock: lock, timeout: 1, pollInterval: 0) {
            reads += 1
            if reads == 1 {
                state.pid = 123
            } else if reads == 2 {
                let competingLock = try? CaptureLock(url: lockURL)
                XCTAssertNil(competingLock)
                competingLock?.release()
                state.pid = 456
            } else {
                let stopLock = try? CaptureLock(url: lockURL)
                XCTAssertNotNil(stopLock)
                stopLock?.release()
                state.status = .recording
            }
            return state
        }
        XCTAssertEqual(reads, 3)
        XCTAssertEqual(result.status, .recording)
    }

    func testStoppedBeforeRecordingReturnsCancellation() throws {
        let lockURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: lockURL) }
        let lock = try CaptureLock(url: lockURL)
        var state = CaptureState(token: "token", status: .stopped, requestedApp: "app", outputDir: "output", outputPath: "output", metadataPath: "metadata")
        state.pid = 456
        XCTAssertThrowsError(try CaptureCLI.waitForStart(token: "token", starterPID: 123, commandLock: lock, timeout: 1, pollInterval: 0) { state }) { error in
            XCTAssertEqual(error.localizedDescription, "Capture was stopped before startup completed.")
        }
    }

    func testSupersededTokenFailsImmediately() throws {
        let lockURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: lockURL) }
        let lock = try CaptureLock(url: lockURL)
        let state = CaptureState(token: "new", status: .starting, requestedApp: "app", outputDir: "output", outputPath: "output", metadataPath: "metadata")
        var reads = 0
        XCTAssertThrowsError(try CaptureCLI.waitForStart(token: "old", starterPID: 123, commandLock: lock, timeout: 1, pollInterval: 0) {
            reads += 1
            return state
        }) { error in
            XCTAssertEqual(error.localizedDescription, "Capture session was replaced while waiting for the agent.")
        }
        XCTAssertEqual(reads, 1)
    }
}
