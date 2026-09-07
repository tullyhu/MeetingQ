// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MeetingQ",
    platforms: [.macOS("15.0")],
    targets: [
        .executableTarget(
            name: "MeetingQ",
            path: "Sources/MeetingQ"
        )
    ]
)
