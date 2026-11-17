// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StarlinkMenuBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "StarlinkMenuBar",
            dependencies: ["Orbits"],
            path: "Sources/StarlinkMenuBar"
        ),
        /// SGP4 (a port of Vallado's reference implementation), TLE parsing, and the simplified Kepler model
        /// the sky view animates satellites with.
        .target(name: "Orbits", path: "Sources/Orbits"),
        .testTarget(
            name: "OrbitsTests",
            dependencies: ["Orbits"],
            path: "Tests/OrbitsTests",
            resources: [.copy("Resources")]
        ),
    ]
)
