// swift-tools-version: 6.0

// ScoreKit: MusicXML -> playback timeline -> engraving layout -> SwiftUI.
// The core depends only on Foundation (plus FoundationXML on Linux) and
// ZIPFoundation for .mxl archives, so `swift test` runs on Linux too.
import PackageDescription

let package = Package(
    name: "ScoreKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "ScoreKit", targets: ["ScoreKit"]),
        .library(name: "ScoreKitUI", targets: ["ScoreKitUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
    ],
    targets: [
        .target(name: "ScoreKit", dependencies: ["ZIPFoundation"]),
        .target(name: "ScoreKitUI", dependencies: ["ScoreKit"]),
        // Debug tool: renders a layout to SVG. An executable target only, deliberately not a
        // product, so it never reaches the app's dependency graph.
        .executableTarget(name: "scorekit-svg", dependencies: ["ScoreKit"]),
        .testTarget(
            name: "ScoreKitTests",
            dependencies: ["ScoreKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
