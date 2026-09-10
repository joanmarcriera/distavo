// swift-tools-version: 6.2
import PackageDescription

// On-device engines for Distavo, kept OUT of DistavoCore so the core package
// stays dependency-free and `cd DistavoCore && swift test` stays fast.
//
// - argmax-oss-swift: WhisperKit (Core ML Whisper, incl. the BSC Catalan
//   fine-tunes from Marc's Hugging Face repo) + SpeakerKit (pyannote), MIT.
// - FluidAudio: NVIDIA Parakeet TDT v3 on the Neural Engine, Apache-2.0.
//   Pinned by REVISION: the `NemoTextProcessing` trait (which lets us drop its
//   prebuilt text-normalisation xcframework) landed on main on 2026-09-09 and is
//   in no tag yet. `traits: []` requires this manifest to be tools 6.2, hence
//   the bump; `swiftLanguageModes: [.v5]` keeps our own targets in Swift 5 mode
//   (dependencies keep theirs). Move to the first tag containing commit 6b90a08.
let package = Package(
    name: "DistavoEmbedded",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DistavoEmbedded", targets: ["DistavoEmbedded"]),
    ],
    dependencies: [
        .package(path: "../DistavoCore"),
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.0.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git",
                 revision: "41540ea237350afe5117a082b5c28eda642d0612",
                 traits: []),
    ],
    targets: [
        .target(
            name: "DistavoEmbedded",
            dependencies: [
                .product(name: "DistavoCore", package: "DistavoCore"),
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "SpeakerKit", package: "argmax-oss-swift"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "DistavoEmbeddedTests",
            dependencies: ["DistavoEmbedded"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
