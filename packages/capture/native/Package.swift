// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "capture",
    platforms: [.macOS("15.0")],
    products: [
        .library(name: "CaptureCore", targets: ["CaptureCore"]),
        .executable(name: "capture", targets: ["CaptureCLI"]),
        .executable(name: "CaptureAgent", targets: ["CaptureAgent"])
    ],
    targets: [
        .target(name: "CaptureCore"),
        .executableTarget(name: "CaptureCLI", dependencies: ["CaptureCore"]),
        .executableTarget(name: "CaptureAgent", dependencies: ["CaptureCore"]),
        .testTarget(name: "CaptureCoreTests", dependencies: ["CaptureCore"])
    ],
    swiftLanguageVersions: [.v5]
)
