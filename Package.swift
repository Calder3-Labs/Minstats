// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MinStats",
    // MinStatsProtocol is shared with the iOS companion app; the MinStats
    // executable itself stays macOS-only.
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "MinStatsProtocol", targets: ["MinStatsProtocol"])
    ],
    targets: [
        .target(name: "MinStatsProtocol"),
        .target(
            name: "PrivateIOKit",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .executableTarget(
            name: "MinStats",
            dependencies: ["PrivateIOKit", "MinStatsProtocol"]
        ),
    ]
)
