// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MeetingQ",
    platforms: [.macOS("15.0")],
    dependencies: [
        // On-device speaker diarization (CAM++ speaker embeddings, CoreML/ANE).
        // Models are downloaded at runtime from HuggingFace and never bundled.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.17.7")
    ],
    targets: [
        .target(
            name: "MeetingQCore",
            path: "Sources/MeetingQCore"
        ),
        .executableTarget(
            name: "MeetingQ",
            dependencies: [
                "MeetingQCore",
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            path: "Sources/MeetingQ"
        ),
        .testTarget(
            name: "MeetingQCoreTests",
            dependencies: ["MeetingQCore"],
            path: "Tests/MeetingQCoreTests"
        )
    ]
)
