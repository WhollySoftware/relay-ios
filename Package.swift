// swift-tools-version: 5.10
// Relay iOS SDK — two products, same split as the web packages:
//   RelayCore  headless client (REST + realtime gateway + observable ChatStore). Foundation only,
//              so it also builds/tests on macOS with plain `swift build` / `swift test`.
//   RelayUI    drop-in SwiftUI chat kit on top of RelayCore.
import PackageDescription

let package = Package(
    name: "Relay",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "RelayCore", targets: ["RelayCore"]),
        .library(name: "RelayUI", targets: ["RelayUI"]),
        .library(name: "RelayCall", targets: ["RelayCall"]),
    ],
    dependencies: [
        // Google WebRTC as a binary xcframework (same package DevBattel ships with).
        .package(url: "https://github.com/stasel/WebRTC", from: "120.0.0"),
    ],
    targets: [
        .target(
            name: "RelayCore",
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .target(
            name: "RelayUI",
            dependencies: ["RelayCore"],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        // 1:1 audio/video calls: WebRTC peer connection + call state machine + CallKit. Separate
        // product so chat-only hosts don't pull the ~40MB WebRTC binary.
        .target(
            name: "RelayCall",
            dependencies: ["RelayCore", .product(name: "WebRTC", package: "WebRTC")]
        ),
        .testTarget(name: "RelayCoreTests", dependencies: ["RelayCore"]),
    ]
)
