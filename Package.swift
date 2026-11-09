// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StarlinkMenuBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "StarlinkMenuBar",
            path: "Sources/StarlinkMenuBar"
        )
    ]
)
