// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "live",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "LiveCore", targets: ["LiveCore"]),
        .executable(name: "live", targets: ["LiveCLI"]),
        .executable(name: "live-worker", targets: ["LiveWorker"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.5"),
    ],
    targets: [
        .target(name: "LiveCore"),
        .executableTarget(name: "LiveCLI", dependencies: ["LiveCore"]),
        .executableTarget(
            name: "LiveWorker",
            dependencies: ["LiveCore", .product(name: "FluidAudio", package: "FluidAudio")]
        ),
        .testTarget(name: "LiveCoreTests", dependencies: ["LiveCore"]),
    ]
)
