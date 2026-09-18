// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AIUsageCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "AIUsageCore", targets: ["AIUsageCore"])],
    targets: [
        .target(name: "AIUsageCore"),
        .testTarget(name: "AIUsageCoreTests", dependencies: ["AIUsageCore"]),
    ]
)
