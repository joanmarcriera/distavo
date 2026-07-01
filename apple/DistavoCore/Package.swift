// swift-tools-version:5.9
import PackageDescription

// UI-free core of Distavo: config, state, transcript cleaning, validation, and
// the summarisation prompt — ported from the Python `meeting_pipeline` package
// and verified against it with parity tests (`swift test`). The macOS app links
// this package; AppKit/AVFoundation/SwiftUI stay in the app target.
let package = Package(
    name: "DistavoCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DistavoCore", targets: ["DistavoCore"]),
    ],
    targets: [
        .target(name: "DistavoCore"),
        .testTarget(
            name: "DistavoCoreTests",
            dependencies: ["DistavoCore"],
            resources: [.process("Fixtures")]
        ),
    ]
)
