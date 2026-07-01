import Foundation

// Port of `meeting_pipeline/config.py`. JSON keys match the Python schema exactly
// so a watcher-config.json written by either side round-trips. Missing keys fall
// back to defaults (the Swift equivalent of Python's deep_merge onto DEFAULTS).

public struct OllamaTarget: Codable, Equatable {
    public var url: String
    public var model: String

    public init(url: String = "http://127.0.0.1:11434", model: String = "llama3.1:8b") {
        self.url = url
        self.model = model
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = OllamaTarget()
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? d.url
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? d.model
    }
}

public struct SummariseOptions: Codable, Equatable {
    public var numCtx: Int
    public var temperature: Double
    public var topP: Double
    public var seed: Int
    public var numPredict: Int
    public var repeatPenalty: Double
    public var repeatLastN: Int

    enum CodingKeys: String, CodingKey {
        case numCtx = "num_ctx", temperature, topP = "top_p", seed
        case numPredict = "num_predict", repeatPenalty = "repeat_penalty", repeatLastN = "repeat_last_n"
    }

    public init(numCtx: Int = 65536, temperature: Double = 0.1, topP: Double = 0.85,
                seed: Int = 42, numPredict: Int = 6144, repeatPenalty: Double = 1.15,
                repeatLastN: Int = 512) {
        self.numCtx = numCtx; self.temperature = temperature; self.topP = topP
        self.seed = seed; self.numPredict = numPredict
        self.repeatPenalty = repeatPenalty; self.repeatLastN = repeatLastN
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SummariseOptions()
        numCtx = try c.decodeIfPresent(Int.self, forKey: .numCtx) ?? d.numCtx
        temperature = try c.decodeIfPresent(Double.self, forKey: .temperature) ?? d.temperature
        topP = try c.decodeIfPresent(Double.self, forKey: .topP) ?? d.topP
        seed = try c.decodeIfPresent(Int.self, forKey: .seed) ?? d.seed
        numPredict = try c.decodeIfPresent(Int.self, forKey: .numPredict) ?? d.numPredict
        repeatPenalty = try c.decodeIfPresent(Double.self, forKey: .repeatPenalty) ?? d.repeatPenalty
        repeatLastN = try c.decodeIfPresent(Int.self, forKey: .repeatLastN) ?? d.repeatLastN
    }
}

public struct TranscribeConfig: Codable, Equatable {
    /// "embedded" (WhisperKit on this Mac) or "server" (a WhisperX URL).
    /// Defaults to "server" so a pre-existing config that lacks the key keeps
    /// its WhisperX setup untouched; fresh installs opt into "embedded" via
    /// `Config.recommendedForThisMac()`.
    public var backend: String
    public var whisperxURL: String
    public var model: String
    /// Catalog id from `EmbeddedModelCatalog` (not a WhisperKit repo name).
    public var embeddedModel: String
    public var language: String
    public var diarize: Bool
    public var numSpeakers: Int

    enum CodingKeys: String, CodingKey {
        case backend, whisperxURL = "whisperx_url", model, embeddedModel = "embedded_model"
        case language, diarize, numSpeakers = "num_speakers"
    }

    public init(backend: String = "server", whisperxURL: String = "http://127.0.0.1:9000",
                model: String = "medium", embeddedModel: String = EmbeddedModelCatalog.defaultModelID,
                language: String = "en", diarize: Bool = true, numSpeakers: Int = 2) {
        self.backend = backend; self.whisperxURL = whisperxURL; self.model = model
        self.embeddedModel = embeddedModel; self.language = language
        self.diarize = diarize; self.numSpeakers = numSpeakers
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TranscribeConfig()
        backend = try c.decodeIfPresent(String.self, forKey: .backend) ?? d.backend
        whisperxURL = try c.decodeIfPresent(String.self, forKey: .whisperxURL) ?? d.whisperxURL
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? d.model
        embeddedModel = try c.decodeIfPresent(String.self, forKey: .embeddedModel) ?? d.embeddedModel
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? d.language
        diarize = try c.decodeIfPresent(Bool.self, forKey: .diarize) ?? d.diarize
        numSpeakers = try c.decodeIfPresent(Int.self, forKey: .numSpeakers) ?? d.numSpeakers
    }
}

public struct SummariseConfig: Codable, Equatable {
    public var backend: String
    /// Both `server` and `local` are user-controlled Ollama endpoints. Distavo has
    /// NO cloud/hosted summarisation path by design — real transcript content is
    /// only ever sent to these user-configured URLs. Do not add a cloud backend.
    public var server: OllamaTarget
    public var local: OllamaTarget
    public var allowLocalFallback: Bool
    public var options: SummariseOptions

    enum CodingKeys: String, CodingKey {
        case backend, server, local, allowLocalFallback = "allow_local_fallback", options
    }

    public init(backend: String = "server", server: OllamaTarget = .init(),
                local: OllamaTarget = .init(), allowLocalFallback: Bool = false,
                options: SummariseOptions = .init()) {
        self.backend = backend; self.server = server; self.local = local
        self.allowLocalFallback = allowLocalFallback; self.options = options
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SummariseConfig()
        backend = try c.decodeIfPresent(String.self, forKey: .backend) ?? d.backend
        server = try c.decodeIfPresent(OllamaTarget.self, forKey: .server) ?? d.server
        local = try c.decodeIfPresent(OllamaTarget.self, forKey: .local) ?? d.local
        allowLocalFallback = try c.decodeIfPresent(Bool.self, forKey: .allowLocalFallback) ?? d.allowLocalFallback
        options = try c.decodeIfPresent(SummariseOptions.self, forKey: .options) ?? d.options
    }
}

public struct Config: Codable, Equatable {
    public var watchIntervalSeconds: Int
    public var recordingsDir: String
    public var notesDir: String
    public var workDir: String
    public var transcribe: TranscribeConfig
    public var summarise: SummariseConfig
    public var noteOwner: String
    public var userSpeaker: String

    enum CodingKeys: String, CodingKey {
        case watchIntervalSeconds = "watch_interval_seconds"
        case recordingsDir = "recordings_dir", notesDir = "notes_dir", workDir = "work_dir"
        case transcribe, summarise
        case noteOwner = "note_owner", userSpeaker = "user_speaker"
    }

    public init(watchIntervalSeconds: Int = 20,
                recordingsDir: String = "~/Documents/Distavo/recordings",
                notesDir: String = "~/Documents/Distavo/notes",
                workDir: String = "~/Library/Application Support/Distavo/work",
                transcribe: TranscribeConfig = .init(),
                summarise: SummariseConfig = .init(),
                noteOwner: String = "Me",
                userSpeaker: String = "unknown") {
        self.watchIntervalSeconds = watchIntervalSeconds
        self.recordingsDir = recordingsDir; self.notesDir = notesDir; self.workDir = workDir
        self.transcribe = transcribe; self.summarise = summarise
        self.noteOwner = noteOwner; self.userSpeaker = userSpeaker
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        watchIntervalSeconds = try c.decodeIfPresent(Int.self, forKey: .watchIntervalSeconds) ?? d.watchIntervalSeconds
        recordingsDir = try c.decodeIfPresent(String.self, forKey: .recordingsDir) ?? d.recordingsDir
        notesDir = try c.decodeIfPresent(String.self, forKey: .notesDir) ?? d.notesDir
        workDir = try c.decodeIfPresent(String.self, forKey: .workDir) ?? d.workDir
        transcribe = try c.decodeIfPresent(TranscribeConfig.self, forKey: .transcribe) ?? d.transcribe
        summarise = try c.decodeIfPresent(SummariseConfig.self, forKey: .summarise) ?? d.summarise
        noteOwner = try c.decodeIfPresent(String.self, forKey: .noteOwner) ?? d.noteOwner
        userSpeaker = try c.decodeIfPresent(String.self, forKey: .userSpeaker) ?? d.userSpeaker
    }

    // MARK: Paths

    /// Base for resolving bare-relative path settings (mirrors Python DATA_BASE_DIR).
    public static var dataBaseDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Distavo")
    }

    /// Default config location (matches the Python app for cross-compat migration).
    public static var defaultConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Distavo/watcher-config.json")
    }

    /// Expand `~`; absolute values unchanged; bare-relative values resolve under
    /// `dataBaseDir` (never the install/repo dir).
    public static func resolvePath(_ value: String) -> URL {
        let expanded = (value as NSString).expandingTildeInPath
        if (expanded as NSString).isAbsolutePath { return URL(fileURLWithPath: expanded) }
        return dataBaseDir.appendingPathComponent(expanded).standardizedFileURL
    }

    // MARK: Load / save

    /// Defaults for a Mac with no config yet: transcription runs on-device when
    /// the hardware supports it (with the model that fits its RAM), otherwise
    /// the classic WhisperX-server setup. Existing config files never pass
    /// through here — their missing keys decode to the "server" default, so an
    /// upgrade can't silently switch a working WhisperX user to embedded.
    public static func recommendedForThisMac(
        embeddedSupported: Bool = HardwareProbe.supportsEmbeddedTranscription,
        memoryBytes: UInt64 = HardwareProbe.physicalMemoryBytes
    ) -> Config {
        var cfg = Config()
        if embeddedSupported {
            cfg.transcribe.backend = "embedded"
            cfg.transcribe.embeddedModel = EmbeddedModelCatalog.recommended(memoryBytes: memoryBytes).id
        }
        return cfg
    }

    public static func load(from url: URL, fileManager: FileManager = .default,
                            fresh: @autoclosure () -> Config = Config()) throws -> Config {
        if !fileManager.fileExists(atPath: url.path) {
            let defaults = fresh()
            try save(defaults, to: url, fileManager: fileManager)
            return defaults
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Config.self, from: data)
    }

    public static func save(_ cfg: Config, to url: URL, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Atomic: a force-quit mid-write must not leave a half-written config
        // that fails to decode on next launch (losing all the user's settings).
        try encoder.encode(cfg).write(to: url, options: .atomic)
    }

    // MARK: Environment overrides (for the gated live test harness)

    /// Override endpoints from env without baking them in. Used by the LAN-only
    /// live test; the app itself reads URLs from the config UI.
    public mutating func applyEnvOverrides(_ env: [String: String] = ProcessInfo.processInfo.environment) {
        if let w = env["WHISPERX_URL"], !w.isEmpty { transcribe.whisperxURL = w }
        if let o = env["OLLAMA_URL"], !o.isEmpty { summarise.server.url = o; summarise.local.url = o }
        if let m = env["OLLAMA_MODEL"], !m.isEmpty { summarise.server.model = m; summarise.local.model = m }
    }
}
