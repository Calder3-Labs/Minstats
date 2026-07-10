// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MinStats",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "PrivateIOKit",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .executableTarget(
            name: "MinStats",
            dependencies: ["PrivateIOKit"]
        ),
    ]
)
