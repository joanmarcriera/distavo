// swift-tools-version:5.10
import PackageDescription

// On-device transcription engine for Distavo, kept OUT of DistavoCore so the
// core package stays dependency-free and `cd DistavoCore && swift test` stays
// fast. This package wraps WhisperKit (transcription) + SpeakerKit (pyannote
// diarization) from Argmax's MIT-licensed SDK and adapts their output to the
// WhisperX response shape the pipeline already consumes (see NOTICES.md).
let package = Package(
    name: "DistavoEmbedded",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DistavoEmbedded", targets: ["DistavoEmbedded"]),
    ],
    dependencies: [
        .package(path: "../DistavoCore"),
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "DistavoEmbedded",
            dependencies: [
                .product(name: "DistavoCore", package: "DistavoCore"),
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "SpeakerKit", package: "argmax-oss-swift"),
            ]
        ),
        .testTarget(
            name: "DistavoEmbeddedTests",
            dependencies: ["DistavoEmbedded"]
        ),
    ]
)
