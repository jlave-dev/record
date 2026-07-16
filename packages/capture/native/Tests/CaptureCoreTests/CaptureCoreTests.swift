import CaptureCore
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
}
