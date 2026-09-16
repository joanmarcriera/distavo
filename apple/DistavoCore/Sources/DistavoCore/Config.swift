import Foundation

// Port of `meeting_pipeline/config.py`. JSON keys match the Python schema exactly
// so a watcher-config.json written by either side round-trips. Missing keys fall
// back to defaults (the Swift equivalent of Python's deep_merge onto DEFAULTS).

public struct OllamaTarget: Codable, Equatable {
    public var url: String
    public var model: String

    /// Default model: gemma4:26b for the server target since 1.12 (the
    /// 2026-09-09 bake-off, Vikunja #2063); the local (on-this-Mac) target
    /// keeps the small llama3.1:8b. Existing config files carry their own
    /// `model` key and are not changed by this default.
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
                seed: Int = 42, numPredict: Int = 6144, repeatPenalty: Double = 1.05,
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
    /// Which BSC catalog id automatic Catalan routing should prefer.
    /// See `effectivePreferredCatalanModel` for the validated accessor.
    public var preferredCatalanModel: String

    enum CodingKeys: String, CodingKey {
        case backend, whisperxURL = "whisperx_url", model, embeddedModel = "embedded_model"
        case language, diarize, numSpeakers = "num_speakers"
        case preferredCatalanModel = "preferred_catalan_model"
    }

    public init(backend: String = "server", whisperxURL: String = "http://127.0.0.1:9000",
                model: String = "medium", embeddedModel: String = EmbeddedModelCatalog.defaultModelID,
                language: String = "en", diarize: Bool = true, numSpeakers: Int = 2,
                preferredCatalanModel: String = "bsc-los") {
        self.backend = backend; self.whisperxURL = whisperxURL; self.model = model
        self.embeddedModel = embeddedModel; self.language = language
        self.diarize = diarize; self.numSpeakers = numSpeakers
        self.preferredCatalanModel = preferredCatalanModel
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
        preferredCatalanModel = try c.decodeIfPresent(String.self, forKey: .preferredCatalanModel) ?? d.preferredCatalanModel
    }

    /// Which BSC model automatic routing uses for Catalan; an unknown value
    /// falls back to Languages of Spain rather than failing the pipeline.
    public var effectivePreferredCatalanModel: String {
        ["bsc-los", "bsc-ca-3370h"].contains(preferredCatalanModel) ? preferredCatalanModel : "bsc-los"
    }
}

public struct SummariseConfig: Codable, Equatable {
    /// "server" / "local" (both Ollama) or "embedded" (Apple Foundation Models
    /// on this Mac). "embedded" is only honoured when `embeddedEnabled` is true —
    /// see `Pipeline.chooseSummariser`.
    public var backend: String
    /// Both `server` and `local` are user-controlled Ollama endpoints. Distavo has
    /// NO cloud/hosted summarisation path by design — real transcript content is
    /// only ever sent to these user-configured URLs. Do not add a cloud backend.
    /// The "embedded" backend is on-device and likewise never leaves the Mac;
    /// Apple's Private Cloud Compute model is deliberately NOT used (see
    /// docs/embedded-summarisation-decision.md).
    public var server: OllamaTarget
    public var local: OllamaTarget
    public var allowLocalFallback: Bool
    /// Feature flag for on-device summarisation (Vikunja #336). Defaults to
    /// false, so existing configs and fresh installs both keep Ollama. Acts as a
    /// real kill switch: with this false, `backend == "embedded"` falls back to
    /// the Ollama path rather than failing, and Settings does not offer it.
    public var embeddedEnabled: Bool
    public var options: SummariseOptions
    /// Which prompt the Ollama path uses (Vikunja #2063). The on-device
    /// Foundation Models path always uses `classic` (context budget).
    /// **Classic for any config predating the key**: on the Catalan reference
    /// meeting llama3.1:8b (the model every existing config names) loses
    /// the section structure under the facts-first prompt and copies the
    /// prompt's example dates into the ledger, while gemma4:26b is excellent
    /// with it — so facts-first is paired with the gemma default for fresh
    /// installs (`recommendedForThisMac`) and offered in Settings.
    public var promptStyle: Prompt.Style

    enum CodingKeys: String, CodingKey {
        case backend, server, local, allowLocalFallback = "allow_local_fallback"
        case embeddedEnabled = "embedded_enabled", options
        case promptStyle = "prompt_style"
    }

    public init(backend: String = "server", server: OllamaTarget = .init(model: "gemma4:26b"),
                local: OllamaTarget = .init(), allowLocalFallback: Bool = false,
                embeddedEnabled: Bool = false,
                options: SummariseOptions = .init(),
                promptStyle: Prompt.Style = .classic) {
        self.backend = backend; self.server = server; self.local = local
        self.allowLocalFallback = allowLocalFallback
        self.embeddedEnabled = embeddedEnabled; self.options = options
        self.promptStyle = promptStyle
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SummariseConfig()
        backend = try c.decodeIfPresent(String.self, forKey: .backend) ?? d.backend
        server = try c.decodeIfPresent(OllamaTarget.self, forKey: .server) ?? d.server
        local = try c.decodeIfPresent(OllamaTarget.self, forKey: .local) ?? d.local
        allowLocalFallback = try c.decodeIfPresent(Bool.self, forKey: .allowLocalFallback) ?? d.allowLocalFallback
        embeddedEnabled = try c.decodeIfPresent(Bool.self, forKey: .embeddedEnabled) ?? d.embeddedEnabled
        options = try c.decodeIfPresent(SummariseOptions.self, forKey: .options) ?? d.options
        // An unknown string (or a missing key) falls back to the default
        // rather than failing the whole config.
        promptStyle = (try? c.decodeIfPresent(String.self, forKey: .promptStyle))
            .flatMap { $0.flatMap(Prompt.Style.init(rawValue:)) } ?? d.promptStyle
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
    /// A recording shorter than this (seconds of audio) is set aside as "too
    /// short" instead of being transcribed and failing on an empty transcript
    /// (Vikunja #2185): the menu offers to delete it. 0 disables the check.
    public var minRecordingSeconds: Int
    /// Once a note is written, replace a bulky WAV recording with the 16 kHz
    /// mono 16-bit copy the transcriber used (~20x smaller, Vikunja #2061).
    /// Only WAV sources are touched, and only when the copy is materially
    /// smaller; the note and transcript are already on disk by then.
    /// **Off for any config file that predates the key** (the original take
    /// is gone once compacted — an upgrade must never do that unasked, same
    /// rule as `transcribe.backend`); fresh installs turn it on via
    /// `recommendedForThisMac()`, and Settings has the toggle.
    public var compactRecordingsAfterNote: Bool
    /// After the built-in recorder stops, ask who was in the meeting (count,
    /// the owner's role, the other participants) and hand that to the
    /// summariser as authoritative context (Vikunja #2182).
    public var askSpeakersOnStop: Bool
    /// "Benchmark this Mac" results (Vikunja #2160), newest run replaces all.
    public var benchmark: [BenchmarkResult]

    enum CodingKeys: String, CodingKey {
        case watchIntervalSeconds = "watch_interval_seconds"
        case recordingsDir = "recordings_dir", notesDir = "notes_dir", workDir = "work_dir"
        case transcribe, summarise
        case noteOwner = "note_owner", userSpeaker = "user_speaker"
        case minRecordingSeconds = "min_recording_seconds"
        case compactRecordingsAfterNote = "compact_recordings_after_note"
        case askSpeakersOnStop = "ask_speakers_on_stop"
        case benchmark
    }

    public init(watchIntervalSeconds: Int = 20,
                recordingsDir: String = "~/Documents/Distavo/recordings",
                notesDir: String = "~/Documents/Distavo/notes",
                workDir: String = "~/Library/Application Support/Distavo/work",
                transcribe: TranscribeConfig = .init(),
                summarise: SummariseConfig = .init(),
                noteOwner: String = "Me",
                userSpeaker: String = "unknown",
                minRecordingSeconds: Int = 15,
                compactRecordingsAfterNote: Bool = false,
                askSpeakersOnStop: Bool = true,
                benchmark: [BenchmarkResult] = []) {
        self.watchIntervalSeconds = watchIntervalSeconds
        self.recordingsDir = recordingsDir; self.notesDir = notesDir; self.workDir = workDir
        self.transcribe = transcribe; self.summarise = summarise
        self.noteOwner = noteOwner; self.userSpeaker = userSpeaker
        self.minRecordingSeconds = minRecordingSeconds
        self.compactRecordingsAfterNote = compactRecordingsAfterNote
        self.askSpeakersOnStop = askSpeakersOnStop
        self.benchmark = benchmark
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
        minRecordingSeconds = try c.decodeIfPresent(Int.self, forKey: .minRecordingSeconds) ?? d.minRecordingSeconds
        compactRecordingsAfterNote = try c.decodeIfPresent(Bool.self, forKey: .compactRecordingsAfterNote) ?? d.compactRecordingsAfterNote
        askSpeakersOnStop = try c.decodeIfPresent(Bool.self, forKey: .askSpeakersOnStop) ?? d.askSpeakersOnStop
        benchmark = (try? c.decodeIfPresent([BenchmarkResult].self, forKey: .benchmark)) ?? d.benchmark
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
    /// the hardware supports it, picking the engine and language automatically
    /// per meeting (spec §5.2), otherwise the classic WhisperX-server setup.
    /// Existing config files never pass through here — their missing keys
    /// decode to the "server" default, so an upgrade can't silently switch a
    /// working WhisperX user to embedded. `memoryBytes` is kept for callers
    /// that still route through `EmbeddedModelCatalog.recommended(memoryBytes:)`.
    public static func recommendedForThisMac(
        embeddedSupported: Bool = HardwareProbe.supportsEmbeddedTranscription,
        memoryBytes: UInt64 = HardwareProbe.physicalMemoryBytes
    ) -> Config {
        var cfg = Config()
        // New installs shrink WAV recordings once the note exists; existing
        // files keep their originals unless the user opts in (Vikunja #2061).
        cfg.compactRecordingsAfterNote = true
        // Fresh installs pair the gemma4:26b default with the facts-first prompt (#2063).
        cfg.summarise.promptStyle = .factsFirst
        if embeddedSupported {
            cfg.transcribe.backend = "embedded"
            // Fresh installs let Distavo pick the engine per meeting (spec §5.2).
            // Existing files never pass through here, so nobody is switched.
            cfg.transcribe.embeddedModel = EmbeddedModelCatalog.automaticID
            cfg.transcribe.language = EmbeddedModelCatalog.automaticID
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
