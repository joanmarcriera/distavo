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
    /// Ids of the opt-in `EmbeddedModelCatalog.languagePacks` automatic routing
    /// may use (Vikunja #2124). Absent in every config written before packs
    /// existed, so it decodes to `[]` and nothing is routed differently until
    /// the user switches a pack on in Settings.
    public var languagePacks: [String]
    /// Custom vocabulary (Vikunja #2939): names/jargon fed to the transcriber as
    /// a prompt and to the summary prompt. Absent in older configs -> `[]`.
    public var vocabulary: [String]
    /// Ordered, case-insensitive whole-word find/replace map applied to the
    /// cleaned transcript. Absent in older configs -> `[]`.
    public var replacements: [ReplacementRule]

    enum CodingKeys: String, CodingKey {
        case vocabulary, replacements
        case backend, whisperxURL = "whisperx_url", model, embeddedModel = "embedded_model"
        case language, diarize, numSpeakers = "num_speakers"
        case preferredCatalanModel = "preferred_catalan_model"
        case languagePacks = "language_packs"
    }

    public init(backend: String = "server", whisperxURL: String = "http://127.0.0.1:9000",
                model: String = "medium", embeddedModel: String = EmbeddedModelCatalog.defaultModelID,
                language: String = "en", diarize: Bool = true, numSpeakers: Int = 2,
                preferredCatalanModel: String = "bsc-los", languagePacks: [String] = [],
                vocabulary: [String] = [], replacements: [ReplacementRule] = []) {
        self.backend = backend; self.whisperxURL = whisperxURL; self.model = model
        self.embeddedModel = embeddedModel; self.language = language
        self.diarize = diarize; self.numSpeakers = numSpeakers
        self.preferredCatalanModel = preferredCatalanModel
        self.languagePacks = languagePacks
        self.vocabulary = vocabulary; self.replacements = replacements
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
        languagePacks = try c.decodeIfPresent([String].self, forKey: .languagePacks) ?? d.languagePacks
        // Lenient like the other newer keys: a wrong type falls back to empty
        // (and bad list entries are dropped) instead of failing the whole
        // config load, which would reset every setting to defaults.
        vocabulary = (try? c.decodeIfPresent(LossyList<String>.self, forKey: .vocabulary))?.elements ?? d.vocabulary
        replacements = (try? c.decodeIfPresent(LossyList<ReplacementRule>.self, forKey: .replacements))?.elements ?? d.replacements
    }

    /// Enabled packs that actually exist in the catalog, in catalog order.
    public var enabledLanguagePacks: [LanguagePack] {
        EmbeddedModelCatalog.languagePacks.filter { languagePacks.contains($0.id) }
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
    /// Which on-device summary model the "embedded" backend runs (Vikunja
    /// #2198): an `EmbeddedSummaryModelCatalog` id. **"apple" for any config
    /// predating the key**, so nothing routes to a downloaded model until the
    /// user picks one. An unknown id is stored as-is and resolves to "apple".
    public var embeddedModel: String
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
    /// "auto" (follow the meeting's dominant detected language for the note
    /// prose; any Whisper language gets an instruction, Catalan/Spanish in
    /// their own words), "en" (always British English, today's behaviour), or
    /// a Whisper language code such as "fr" (always write notes in that
    /// language — Vikunja #2956). Unknown values behave like "en". Same
    /// migration rule as `transcribe.backend`: a config file predating this
    /// key decodes to "en" so no existing user's notes change language
    /// silently; only fresh installs get "auto" via `recommendedForThisMac()`.
    /// Honoured by Ollama and Gemma; Apple's on-device model only for
    /// languages it reports supporting (see `NoteLanguage`).
    public var noteLanguage: String
    /// A larger/more capable Ollama model name for the "re-summarise with a
    /// bigger model" `WhenDoneAction` (Vikunja #2205). Reuses `server.url` —
    /// only the model differs. nil (the default, and for any config
    /// predating the key) means the action has nothing to run, so Settings
    /// hides its checkbox and `WatcherController` skips it.
    public var biggerModel: String?
    /// Summary template id for every recording ("" = none; "standup", "one_on_one",
    /// "interview", "sales_call", "lecture" or "custom" - Vikunja #2940). See
    /// `SummaryTemplateCatalog`. A config predating the key decodes to "" (no change).
    public var template: String
    /// The user's own template as a Markdown outline (`## Heading` + instruction
    /// lines); used when `template` (or a folder/recording choice) is "custom".
    public var customTemplate: String
    /// Subfolder of the recordings dir (relative, "/"-separated) -> template id,
    /// longest prefix wins; overrides `template` for recordings in that folder.
    public var folderTemplates: [String: String]

    enum CodingKeys: String, CodingKey {
        case backend, server, local, allowLocalFallback = "allow_local_fallback"
        case embeddedEnabled = "embedded_enabled", embeddedModel = "embedded_model", options
        case promptStyle = "prompt_style"
        case noteLanguage = "note_language"
        case biggerModel = "bigger_model"
        case template, customTemplate = "custom_template", folderTemplates = "folder_templates"
    }

    public init(backend: String = "server", server: OllamaTarget = .init(model: "gemma4:26b"),
                local: OllamaTarget = .init(), allowLocalFallback: Bool = false,
                embeddedEnabled: Bool = false,
                embeddedModel: String = EmbeddedSummaryModelCatalog.appleID,
                options: SummariseOptions = .init(),
                promptStyle: Prompt.Style = .classic,
                noteLanguage: String = "en",
                biggerModel: String? = nil,
                template: String = "", customTemplate: String = "",
                folderTemplates: [String: String] = [:]) {
        self.backend = backend; self.server = server; self.local = local
        self.allowLocalFallback = allowLocalFallback
        self.embeddedEnabled = embeddedEnabled; self.embeddedModel = embeddedModel
        self.options = options
        self.promptStyle = promptStyle
        self.noteLanguage = noteLanguage
        self.biggerModel = biggerModel
        self.template = template; self.customTemplate = customTemplate
        self.folderTemplates = folderTemplates
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SummariseConfig()
        backend = try c.decodeIfPresent(String.self, forKey: .backend) ?? d.backend
        server = try c.decodeIfPresent(OllamaTarget.self, forKey: .server) ?? d.server
        local = try c.decodeIfPresent(OllamaTarget.self, forKey: .local) ?? d.local
        allowLocalFallback = try c.decodeIfPresent(Bool.self, forKey: .allowLocalFallback) ?? d.allowLocalFallback
        embeddedEnabled = try c.decodeIfPresent(Bool.self, forKey: .embeddedEnabled) ?? d.embeddedEnabled
        embeddedModel = try c.decodeIfPresent(String.self, forKey: .embeddedModel) ?? d.embeddedModel
        options = try c.decodeIfPresent(SummariseOptions.self, forKey: .options) ?? d.options
        // An unknown string (or a missing key) falls back to the default
        // rather than failing the whole config.
        promptStyle = (try? c.decodeIfPresent(String.self, forKey: .promptStyle))
            .flatMap { $0.flatMap(Prompt.Style.init(rawValue:)) } ?? d.promptStyle
        noteLanguage = try c.decodeIfPresent(String.self, forKey: .noteLanguage) ?? d.noteLanguage
        biggerModel = try c.decodeIfPresent(String.self, forKey: .biggerModel) ?? d.biggerModel
        // Template keys (#2940): a wrong-typed value falls back to "no template" rather
        // than failing the whole config.
        template = ((try? c.decodeIfPresent(String.self, forKey: .template)) ?? nil) ?? d.template
        customTemplate = ((try? c.decodeIfPresent(String.self, forKey: .customTemplate)) ?? nil) ?? d.customTemplate
        folderTemplates = ((try? c.decodeIfPresent([String: String].self, forKey: .folderTemplates)) ?? nil)
            ?? d.folderTemplates
    }
}

/// One action to take once a recording finishes processing (Vikunja #2205),
/// replacing #2199's single `open_when_done` choice with a checklist so
/// several can run together — e.g. open the note *and* queue a bigger-model
/// re-transcribe. An unrecognised entry is dropped (`compactMap` at decode)
/// rather than failing the whole config, the same fallback spirit as
/// `Prompt.Style`.
public enum WhenDoneAction: String, Codable, Equatable, Sendable, CaseIterable {
    case openNote = "open_note"
    case openTranscript = "open_transcript"
    /// Re-run transcription via `EmbeddedModelCatalog.nextBigger(for:language:)`
    /// (built-in engine only); a no-op when there is no bigger model for the
    /// language transcribed.
    case retryTranscribeBigger = "retry_transcribe_bigger"
    /// Re-run summarisation against `SummariseConfig.biggerModel`; a no-op
    /// when that is unset.
    case retrySummariseBigger = "retry_summarise_bigger"
}

/// Reads only the legacy `open_when_done` scalar key, for migrating config
/// files written before 1.15 dropped it in favour of `when_done` (an array).
/// Kept separate from `Config.CodingKeys` so that enum doesn't need a case
/// with no matching stored property (which would break `Encodable` synthesis).
private enum LegacyWhenDoneKey: String, CodingKey {
    case openWhenDone = "open_when_done"
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
    /// Silence handling for the built-in recorder (Vikunja #2665). Two
    /// independent options, both **off** for any config predating them and
    /// for fresh installs (an unwanted stop loses audio irrecoverably); the
    /// minute values are only pre-filled defaults. Minutes clamp to 1...60.
    /// "Suggest" posts a notification after N silent minutes and never stops.
    public var suggestStopOnSilence: Bool
    public var suggestStopSilenceMinutes: Int
    /// "Auto-stop" ends the recording after M silent minutes (see `SilenceMonitor`).
    public var autoStopOnSilence: Bool
    public var autoStopSilenceMinutes: Int
    /// "Benchmark this Mac" results (Vikunja #2160), newest run replaces all.
    public var benchmark: [BenchmarkResult]
    /// Actions to run once a recording finishes (Vikunja #2205, superseding
    /// #2199's single-choice `open_when_done`). Defaults to `[]`; a config
    /// predating either key decodes to `[]` too, so upgrading never starts
    /// opening files or queueing re-runs unasked. See `WhenDoneAction`.
    public var whenDone: [WhenDoneAction]

    enum CodingKeys: String, CodingKey {
        case watchIntervalSeconds = "watch_interval_seconds"
        case recordingsDir = "recordings_dir", notesDir = "notes_dir", workDir = "work_dir"
        case transcribe, summarise
        case noteOwner = "note_owner", userSpeaker = "user_speaker"
        case minRecordingSeconds = "min_recording_seconds"
        case compactRecordingsAfterNote = "compact_recordings_after_note"
        case askSpeakersOnStop = "ask_speakers_on_stop"
        case suggestStopOnSilence = "suggest_stop_on_silence"
        case suggestStopSilenceMinutes = "suggest_stop_silence_minutes"
        case autoStopOnSilence = "auto_stop_on_silence"
        case autoStopSilenceMinutes = "auto_stop_silence_minutes"
        case benchmark
        case whenDone = "when_done"
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
                suggestStopOnSilence: Bool = false,
                suggestStopSilenceMinutes: Int = 2,
                autoStopOnSilence: Bool = false,
                autoStopSilenceMinutes: Int = 5,
                benchmark: [BenchmarkResult] = [],
                whenDone: [WhenDoneAction] = []) {
        self.watchIntervalSeconds = watchIntervalSeconds
        self.recordingsDir = recordingsDir; self.notesDir = notesDir; self.workDir = workDir
        self.transcribe = transcribe; self.summarise = summarise
        self.noteOwner = noteOwner; self.userSpeaker = userSpeaker
        self.minRecordingSeconds = minRecordingSeconds
        self.compactRecordingsAfterNote = compactRecordingsAfterNote
        self.askSpeakersOnStop = askSpeakersOnStop
        self.suggestStopOnSilence = suggestStopOnSilence
        self.suggestStopSilenceMinutes = Config.clampSilenceMinutes(suggestStopSilenceMinutes)
        self.autoStopOnSilence = autoStopOnSilence
        self.autoStopSilenceMinutes = Config.clampSilenceMinutes(autoStopSilenceMinutes)
        self.benchmark = benchmark
        self.whenDone = whenDone
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
        // Silence options: `try?` so a wrong-typed value falls back to the
        // default instead of failing the whole config; minutes are clamped.
        suggestStopOnSilence = (try? c.decodeIfPresent(Bool.self, forKey: .suggestStopOnSilence)).flatMap { $0 } ?? d.suggestStopOnSilence
        suggestStopSilenceMinutes = Config.clampSilenceMinutes((try? c.decodeIfPresent(Int.self, forKey: .suggestStopSilenceMinutes)).flatMap { $0 } ?? d.suggestStopSilenceMinutes)
        autoStopOnSilence = (try? c.decodeIfPresent(Bool.self, forKey: .autoStopOnSilence)).flatMap { $0 } ?? d.autoStopOnSilence
        autoStopSilenceMinutes = Config.clampSilenceMinutes((try? c.decodeIfPresent(Int.self, forKey: .autoStopSilenceMinutes)).flatMap { $0 } ?? d.autoStopSilenceMinutes)
        benchmark = (try? c.decodeIfPresent([BenchmarkResult].self, forKey: .benchmark)) ?? d.benchmark
        // `when_done` (an array); unknown entries are dropped rather than
        // failing the whole config. A config predating it falls back to the
        // legacy `open_when_done` scalar, migrated 1:1; either absent leaves `[]`.
        let decodedWhenDone = (try? c.decodeIfPresent([String].self, forKey: .whenDone)).flatMap { $0 }
        if let decodedWhenDone {
            whenDone = decodedWhenDone.compactMap(WhenDoneAction.init(rawValue:))
        } else {
            let legacy = (try? decoder.container(keyedBy: LegacyWhenDoneKey.self))
                .flatMap { try? $0.decodeIfPresent(String.self, forKey: .openWhenDone) }
                .flatMap { $0 }
            switch legacy {
            case "note": whenDone = [.openNote]
            case "transcript": whenDone = [.openTranscript]
            default: whenDone = d.whenDone
            }
        }
    }

    /// Valid range for the silence-minute settings.
    public static let silenceMinutesRange = 1...60
    static func clampSilenceMinutes(_ m: Int) -> Int {
        min(max(m, silenceMinutesRange.lowerBound), silenceMinutesRange.upperBound)
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
        // Fresh installs follow the meeting's language for the note prose too (#2147).
        cfg.summarise.noteLanguage = "auto"
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
