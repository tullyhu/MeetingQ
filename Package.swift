// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "CalledMe",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "CalledMe",
            path: "Sources/CalledMe"
        )
    ]
)
