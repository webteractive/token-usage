// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TokenUsage",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TokenUsageCore", targets: ["TokenUsageCore"]),
    ],
    targets: [
        .target(
            name: "TokenUsageCore",
            resources: [.copy("Resources/statusline-shim.sh")]
        ),
        .testTarget(
            name: "TokenUsageCoreTests",
            dependencies: ["TokenUsageCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
