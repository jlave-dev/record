// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LiveTranscriptionReplay",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "fluid-transcribe", targets: ["FluidTranscribe"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.5"),
    ],
    targets: [
        .executableTarget(
            name: "FluidTranscribe",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]
        ),
    ]
)
