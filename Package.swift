// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StatsMenu",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "PrivateIOKit",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .executableTarget(
            name: "StatsMenu",
            dependencies: ["PrivateIOKit"]
        ),
    ]
)
