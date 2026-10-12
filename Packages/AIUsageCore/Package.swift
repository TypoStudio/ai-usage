// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AIUsageCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AIUsageCore", targets: ["AIUsageCore"]),
        .library(name: "AIUsageFetch", targets: ["AIUsageFetch"]),
        .executable(name: "aiusage", targets: ["aiusage"]),
    ],
    targets: [
        .target(name: "AIUsageCore"),
        // 자격 증명 읽기·토큰 갱신·사용량 조회 — 앱과 `aiusage` CLI 가 같이 쓴다
        .target(name: "AIUsageFetch", dependencies: ["AIUsageCore"]),
        .executableTarget(name: "aiusage", dependencies: ["AIUsageCore", "AIUsageFetch"]),
        .testTarget(name: "AIUsageCoreTests", dependencies: ["AIUsageCore"]),
    ]
)
