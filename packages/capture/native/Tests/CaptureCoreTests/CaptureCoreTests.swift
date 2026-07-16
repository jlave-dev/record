import CaptureCore
import CoreGraphics
import XCTest

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
}
