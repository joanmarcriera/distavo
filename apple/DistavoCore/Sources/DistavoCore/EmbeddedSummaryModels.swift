import Foundation

// Catalogue of on-device *summary* models (Vikunja #2198, slice S1).
//
// Sibling of `EmbeddedModelCatalog` (which lists transcription models). The
// config key `summarise.embedded_model` stores one `id` from here. Pure data
// plus tier filtering, so DistavoCore stays dependency-free; the engines that
// actually run these models live in DistavoEmbedded.

/// Which runtime executes a summary model.
public enum EmbeddedSummaryEngine: String, Equatable, Sendable {
    /// Apple's on-device Foundation Models (macOS 26+, Apple Intelligence).
    case appleFoundationModels
    /// mlx-swift-lm on the GPU (macOS 14+, Apple Silicon), weights downloaded.
    case mlx
}

/// One file of a model snapshot at its pinned revision. `sha256` is known only
/// for LFS files (the Hugging Face API publishes it); small files are checked
/// by size alone.
public struct EmbeddedSummaryModelFile: Equatable, Sendable {
    public let path: String
    public let bytes: Int64
    public let sha256: String?
    public init(path: String, bytes: Int64, sha256: String? = nil) {
        self.path = path; self.bytes = bytes; self.sha256 = sha256
    }
}

/// One selectable on-device summary model.
public struct EmbeddedSummaryModel: Equatable, Identifiable, Sendable {
    /// What `SummariseConfig.embeddedModel` stores.
    public let id: String
    public let displayName: String
    public let engine: EmbeddedSummaryEngine
    /// Hugging Face repo holding the weights; nil for the system model.
    public let repo: String?
    /// Pinned revision of `repo`, so a shipped build never changes under it;
    /// nil until the pinned mirror exists (S5).
    public let revision: String?
    public let downloadMB: Int
    /// Peak memory while generating (measured, spike S0).
    public let ramGB: Double
    /// Physical memory below which the model is neither offered nor routed.
    /// Same rule and `HardwareProbe` source as `EmbeddedModel.minimumMemoryGB`.
    public let minimumMemoryGB: Int
    /// Distavo's own context cap in tokens (it bounds KV-cache RAM), or nil
    /// when the engine reports the window itself (Apple's model).
    public let contextCap: Int?
    /// The prompt template that suits the model's window. Apple's 4096-token
    /// window cannot afford facts-first (Vikunja #2063).
    public let promptStyle: Prompt.Style
    public let detail: String
    /// Every file to download (empty for the system model), with expected sizes.
    public let files: [EmbeddedSummaryModelFile]

    public init(id: String, displayName: String, engine: EmbeddedSummaryEngine, repo: String?,
                revision: String?, downloadMB: Int, ramGB: Double, minimumMemoryGB: Int,
                contextCap: Int?, promptStyle: Prompt.Style, detail: String,
                files: [EmbeddedSummaryModelFile] = []) {
        self.files = files
        self.id = id; self.displayName = displayName; self.engine = engine
        self.repo = repo; self.revision = revision; self.downloadMB = downloadMB
        self.ramGB = ramGB; self.minimumMemoryGB = minimumMemoryGB
        self.contextCap = contextCap; self.promptStyle = promptStyle; self.detail = detail
    }

    /// `https://huggingface.co/<repo>/resolve/<revision>/<path>` — pinned, so the
    /// bytes never change under a shipped build. nil for the system model.
    public func downloadURL(for file: EmbeddedSummaryModelFile) -> URL? {
        guard let repo, let revision else { return nil }
        return URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(file.path)")
    }

    /// The `manifest.json` (same shape as the BSC WhisperKit models'), written
    /// next to the downloaded files so `ModelManifestCheck` can verify them.
    public func manifestJSON() -> Data {
        var entries: [String: [String: Any]] = [:]
        for f in files {
            var e: [String: Any] = ["bytes": f.bytes]
            if let h = f.sha256 { e["sha256"] = h }
            entries[f.path] = e
        }
        return (try? JSONSerialization.data(withJSONObject: ["files": entries], options: [.sortedKeys])) ?? Data()
    }

    /// Whether a Mac with this much physical memory may run the model.
    public func fits(memoryBytes: UInt64 = HardwareProbe.physicalMemoryBytes) -> Bool {
        Int(memoryBytes / (1024 * 1024 * 1024)) >= minimumMemoryGB
    }
}

public enum EmbeddedSummaryModelCatalog {
    /// The id every config predating `summarise.embedded_model` decodes to.
    public static let appleID = "apple"

    /// Only e4b is offered in-app: the 12B tier peaks near 12.5 GB and does not
    /// fit the 16 GB floor, and 26B+ is Ollama's weight class (spike S0).
    public static let models: [EmbeddedSummaryModel] = [
        EmbeddedSummaryModel(
            id: appleID, displayName: "Apple Intelligence (built in)",
            engine: .appleFoundationModels, repo: nil, revision: nil,
            downloadMB: 0, ramGB: 0, minimumMemoryGB: 0, contextCap: nil,
            promptStyle: .classic,
            detail: "Apple's on-device model. English notes, short context, nothing to download."),
        EmbeddedSummaryModel(
            id: "gemma-4-e4b", displayName: "Gemma 4 e4b (local)",
            // Pinned to the revision measured in spike S0 (2026-07-06 upload).
            // PLAN: mirror these files under Marc's own Hugging Face account
            // (with a published manifest) and repoint `repo`; until then the
            // pin protects against upstream changes but not upstream deletion.
            engine: .mlx, repo: "mlx-community/gemma-4-e4b-it-4bit",
            revision: "475b9088d29754a3379866cf5aeb6b41acd313c2",
            downloadMB: 5150, ramGB: 5.5, minimumMemoryGB: 16, contextCap: 16384,
            promptStyle: .factsFirst,
            detail: "Gemma 4 e4b, 4-bit, run on the GPU. Catalan and Spanish notes; ~5 GB download.",
            files: [
                .init(path: "config.json", bytes: 6628),
                .init(path: "generation_config.json", bytes: 208),
                .init(path: "chat_template.jinja", bytes: 17336),
                .init(path: "model.safetensors.index.json", bytes: 240961),
                .init(path: "processor_config.json", bytes: 1316),
                .init(path: "tokenizer_config.json", bytes: 2740),
                .init(path: "tokenizer.json", bytes: 32_169_626,
                      sha256: "cc8d3a0ce36466ccc1278bf987df5f71db1719b9ca6b4118264f45cb627bfe0f"),
                .init(path: "model.safetensors", bytes: 5_146_800_534,
                      sha256: "932b8271fc3fe65adcc78b96c10c6268bbfb13e8f67d1358727c0d6ee97e1eff"),
            ]),
    ]

    /// Look up by config id. An unknown or empty value resolves to Apple's
    /// model — never to a model that needs a download the user did not choose.
    public static func model(id: String) -> EmbeddedSummaryModel {
        models.first { $0.id == id } ?? models.first { $0.id == appleID }!
    }

    /// Entries this Mac may run (the same physical-memory gate as transcription).
    public static func selectable(
        memoryBytes: UInt64 = HardwareProbe.physicalMemoryBytes
    ) -> [EmbeddedSummaryModel] {
        models.filter { $0.fits(memoryBytes: memoryBytes) }
    }
}
