import Foundation

// Support types for the embedded (on-device) transcription backend. The engine
// itself lives in the separate DistavoEmbedded package (it depends on
// WhisperKit); this file holds the dependency-free pieces shared by the engine,
// the settings UI, and the config defaults: which models exist, what they cost
// in download/RAM, and what this Mac can run.

/// Which runtime executes a catalog entry.
public enum EmbeddedEngine: String, Equatable, Sendable {
    case whisperKit   // WhisperKit Core ML (Argmax repo or a custom repo)
    case parakeet     // NVIDIA Parakeet TDT via FluidAudio
}

/// Which spoken languages an entry can transcribe. Used by the router only;
/// a fixed, explicit model choice is always honoured.
public enum LanguageCoverage: Equatable, Sendable {
    case whisper                 // all 99 Whisper languages
    case parakeet                // Parakeet TDT v3's 25 European languages
    case only(Set<String>)       // a fine-tune's languages

    public func covers(_ code: String) -> Bool {
        switch self {
        case .whisper: return WhisperLanguageCatalog.language(forCode: code) != nil
        case .parakeet: return EmbeddedModelCatalog.parakeetLanguages.contains(code)
        case .only(let set): return set.contains(code)
        }
    }
}

/// One selectable on-device transcription model. `id` is what
/// `TranscribeConfig.embeddedModel` stores; `whisperKitName` is the variant
/// folder inside `whisperKitRepo` (or Argmax's `argmaxinc/whisperkit-coreml`
/// when the repo is nil). Parakeet entries have an empty `whisperKitName`.
public struct EmbeddedModel: Equatable, Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let engine: EmbeddedEngine
    public let whisperKitRepo: String?
    public let whisperKitName: String
    public let languages: LanguageCoverage
    public let downloadMB: Int
    public let ramGB: Double
    /// Physical memory below which the model is neither offered nor
    /// auto-routed (spec §6: 16 GB for the fp16 large-v3 fine-tunes until
    /// measured; 0 = no floor).
    public let minimumMemoryGB: Int
    public let detail: String

    /// The synthesized memberwise init is `internal`, so cross-module callers
    /// (Settings, building a synthetic "not available on this Mac" / "not a
    /// known model" row from an existing or ad-hoc entry) need this explicit one.
    public init(id: String, displayName: String, engine: EmbeddedEngine, whisperKitRepo: String?,
                whisperKitName: String, languages: LanguageCoverage, downloadMB: Int, ramGB: Double,
                minimumMemoryGB: Int, detail: String) {
        self.id = id; self.displayName = displayName; self.engine = engine
        self.whisperKitRepo = whisperKitRepo; self.whisperKitName = whisperKitName
        self.languages = languages; self.downloadMB = downloadMB; self.ramGB = ramGB
        self.minimumMemoryGB = minimumMemoryGB; self.detail = detail
    }

    public var downloadLabel: String { "\(downloadMB) MB download" }
    public var ramLabel: String {
        ramGB == ramGB.rounded() ? "~\(Int(ramGB)) GB memory while transcribing"
                                 : "~\(ramGB) GB memory while transcribing"
    }
}

public enum EmbeddedModelCatalog {
    public static let defaultModelID = "large-v3-turbo"
    /// Stored in `embedded_model` (and `language`) to mean "let Distavo choose".
    public static let automaticID = "auto"
    /// The variant used only for language detection (77 MB, Argmax repo).
    public static let languageDetectorName = "openai_whisper-tiny"
    public static let customRepo = "Joanmarcriera/distavo-whisperkit-coreml"

    public static let catalanFamily: Set<String> = ["ca", "gl", "eu"]
    public static let languagesOfSpain: Set<String> = ["ca", "es", "gl", "eu"]
    /// NVIDIA Parakeet TDT 0.6B v3's languages (model card, 25 European).
    public static let parakeetLanguages: Set<String> = [
        "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it",
        "lv", "lt", "mt", "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk",
    ]

    public static let models: [EmbeddedModel] = [
        EmbeddedModel(
            id: "large-v3-turbo", displayName: "Best (Whisper large-v3 turbo)",
            engine: .whisperKit, whisperKitRepo: nil,
            whisperKitName: "openai_whisper-large-v3-v20240930_turbo_632MB",
            languages: .whisper, downloadMB: 632, ramGB: 2, minimumMemoryGB: 0,
            detail: "Highest accuracy across 99 languages; recommended for Macs with 16 GB memory or more."),
        EmbeddedModel(
            id: "small", displayName: "Compact (Whisper small)",
            engine: .whisperKit, whisperKitRepo: nil, whisperKitName: "openai_whisper-small",
            languages: .whisper, downloadMB: 463, ramGB: 1, minimumMemoryGB: 0,
            detail: "Lighter and faster; recommended for Macs with 8 GB memory."),
        EmbeddedModel(
            id: "parakeet-tdt-v3", displayName: "Fast (Parakeet, 25 languages)",
            engine: .parakeet, whisperKitRepo: nil, whisperKitName: "",
            languages: .parakeet, downloadMB: 460, ramGB: 1.5, minimumMemoryGB: 0,
            detail: "Transcribes an hour in seconds on the Neural Engine. English, Spanish, French, German and 21 more European languages — not Catalan."),
        EmbeddedModel(
            id: "bsc-los", displayName: "Català · Castellà · Galego · Euskara (BSC Languages of Spain)",
            engine: .whisperKit, whisperKitRepo: customRepo,
            whisperKitName: "BSC-LT_whisper-large-v3-LoS",
            languages: .only(languagesOfSpain), downloadMB: 3100, ramGB: 4, minimumMemoryGB: 16,
            detail: "Whisper large-v3 fine-tuned by the Barcelona Supercomputing Center on 8,110 hours. Best for Catalan, Spanish and mixed meetings."),
        EmbeddedModel(
            id: "bsc-ca-3370h", displayName: "Català (BSC, 3,370 hours)",
            engine: .whisperKit, whisperKitRepo: customRepo,
            whisperKitName: "BSC-LT_whisper-large-v3-ca-punctuated-3370h",
            languages: .only(["ca"]), downloadMB: 3100, ramGB: 4, minimumMemoryGB: 16,
            detail: "Whisper large-v3 fine-tuned by the Barcelona Supercomputing Center on 3,370 hours of Catalan, with punctuation. Catalan-only meetings."),
    ]

    public static func isAutomatic(_ id: String) -> Bool { id == automaticID }

    /// Look up by config id, falling back to the default so an unknown value in
    /// a hand-edited config (or "auto", which is not a model) degrades gracefully.
    public static func model(id: String) -> EmbeddedModel {
        models.first { $0.id == id } ?? models.first { $0.id == defaultModelID }!
    }

    /// Entries this Mac may run (spec §6 memory gate).
    public static func selectable(
        memoryBytes: UInt64 = HardwareProbe.physicalMemoryBytes
    ) -> [EmbeddedModel] {
        let gb = Int(memoryBytes / (1024 * 1024 * 1024))
        return models.filter { $0.minimumMemoryGB <= gb }
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
