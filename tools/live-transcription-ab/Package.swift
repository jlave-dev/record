// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LiveTranscriptionAB",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "apple-transcribe", targets: ["AppleTranscribe"]),
        .executable(name: "fluid-transcribe", targets: ["FluidTranscribe"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.5"),
    ],
    targets: [
        .target(name: "ABSupport"),
        .executableTarget(name: "AppleTranscribe", dependencies: ["ABSupport"]),
        .executableTarget(
            name: "FluidTranscribe",
            dependencies: ["ABSupport", .product(name: "FluidAudio", package: "FluidAudio")]
        ),
    ]
)
