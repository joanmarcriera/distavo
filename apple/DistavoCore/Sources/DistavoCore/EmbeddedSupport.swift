import Foundation

// Support types for the embedded (on-device) transcription backend. The engine
// itself lives in the separate DistavoEmbedded package (it depends on
// WhisperKit); this file holds the dependency-free pieces shared by the engine,
// the settings UI, and the config defaults: which models exist, what they cost
// in download/RAM, and what this Mac can run.

/// One selectable on-device transcription model. `id` is what
/// `TranscribeConfig.embeddedModel` stores; `whisperKitName` is the variant
/// name inside the `argmaxinc/whisperkit-coreml` Hugging Face repo.
public struct EmbeddedModel: Equatable, Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let whisperKitName: String
    public let downloadMB: Int
    public let ramGB: Double
    public let detail: String

    public var downloadLabel: String { "\(downloadMB) MB download" }
    public var ramLabel: String {
        ramGB == ramGB.rounded() ? "~\(Int(ramGB)) GB memory while transcribing"
                                 : "~\(ramGB) GB memory while transcribing"
    }
}

public enum EmbeddedModelCatalog {
    public static let defaultModelID = "large-v3-turbo"

    public static let models: [EmbeddedModel] = [
        EmbeddedModel(
            id: "large-v3-turbo",
            displayName: "Best (Whisper large-v3 turbo)",
            whisperKitName: "openai_whisper-large-v3-v20240930_turbo_632MB",
            downloadMB: 632,
            ramGB: 2,
            detail: "Highest accuracy; recommended for Macs with 16 GB memory or more."),
        EmbeddedModel(
            id: "small",
            displayName: "Compact (Whisper small)",
            whisperKitName: "openai_whisper-small",
            downloadMB: 463,
            ramGB: 1,
            detail: "Lighter and faster; recommended for Macs with 8 GB memory."),
    ]

    /// Look up by config id, falling back to the default so an unknown value in
    /// a hand-edited config degrades gracefully instead of failing the pipeline.
    public static func model(id: String) -> EmbeddedModel {
        models.first { $0.id == id } ?? models.first { $0.id == defaultModelID }!
    }

    /// Marc's rule: recommend a model the user's Mac can actually run.
    /// ≥ 16 GB physical memory → large-v3-turbo; below that → small.
    public static func recommended(
        memoryBytes: UInt64 = HardwareProbe.physicalMemoryBytes
    ) -> EmbeddedModel {
        let sixteenGB: UInt64 = 16 * 1024 * 1024 * 1024
        return model(id: memoryBytes >= sixteenGB ? "large-v3-turbo" : "small")
    }
}

/// What this Mac can run. WhisperKit's CoreML models are tuned for Apple
/// Silicon (ANE); Intel Macs keep the WhisperX-server backend.
public enum HardwareProbe {
    public static var physicalMemoryBytes: UInt64 { ProcessInfo.processInfo.physicalMemory }

    public static var isAppleSilicon: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        // 1 on Apple Silicon (including x86_64 processes under Rosetta, which
        // still run on an ARM Mac and can use the embedded engine's CPU path);
        // sysctl fails or returns 0 on Intel hardware.
        guard sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 else { return false }
        return value == 1
    }

    public static var supportsEmbeddedTranscription: Bool { isAppleSilicon }
}
