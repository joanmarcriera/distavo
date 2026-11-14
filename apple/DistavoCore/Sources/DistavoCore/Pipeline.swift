import Foundation
import AVFoundation

public enum ProcessStatus: String, Equatable {
    case done
    case skipped
    case deferredNeedLocal = "deferred_need_local"
    /// A dependency was temporarily unavailable (offline model download,
    /// interrupted download, busy model folder). The recording stays pending
    /// and is retried on the next scan — never marked failed.
    case deferred
    case failed
    /// Under `min_recording_seconds` of audio — set aside with a `.tooshort`
    /// marker, never transcribed, never `failed`; the menu offers to delete
    /// the file (Vikunja #2185).
    case tooShort = "too_short"
}

/// Thrown by any `PipelineDeps.transcribe` implementation for a condition that
/// resolves on its own (no internet for a one-time model download, a download
/// interrupted mid-way, a model folder busy with removal). `Pipeline.processOne`
/// clears the `.processing` marker and returns `.deferred` instead of writing a
/// permanent `.failed` marker, which `iterPending` would skip forever.
public struct RetryableDependencyError: Error, Equatable, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Coarse progress reported at each pipeline stage boundary. Works for both
/// transcription backends (unlike the embedded engine's fine-grained progress
/// messages, which the WhisperX server path cannot provide). The app maps these
/// onto the menu-bar icon: `converting → loading`, `transcribing`/`summarising
/// → transcribing`.
public enum ProcessingPhase: String, Equatable, Sendable {
    case converting
    case transcribing
    case summarising
}

/// Where a recording's summary will be produced. Replaces the bare
/// `(url, model)` tuple so the pipeline can express an on-device target that
/// has no endpoint at all (Vikunja #336).
public enum SummariseTarget: Equatable, Sendable {
    /// A user-controlled Ollama endpoint (the `server` or `local` config target).
    case ollama(url: String, model: String)
    /// An on-device model — no network, no endpoint. `model` is an
    /// `EmbeddedSummaryModelCatalog` id ("apple" = Foundation Models); it is
    /// carried here because the summarise closure never sees `Config`
    /// (Vikunja #2198).
    case embedded(model: String)
}

public struct ProcessResult: Equatable {
    public let status: ProcessStatus
    public let base: String
    public let message: String
    public var notePath: URL?
    public var transcriptPath: URL?
    /// "Catalan 92%, English 71%" when the transcribe result carried the
    /// router's detections (the built-in engine in Automatic mode); nil
    /// otherwise. Same text as the note footer (Vikunja #2161).
    public var detectedLanguages: String?
    /// The single highest-probability detected language code (e.g. "ca"),
    /// when the transcribe result carried detections; nil otherwise (the
    /// server path, or the built-in engine outside Automatic mode). Lets a
    /// caller resolve "the language this recording was actually
    /// transcribed in" for `EmbeddedModelCatalog.nextBigger` without
    /// re-deriving it from `detectedLanguages`' display string (Vikunja #2205).
    public var dominantLanguageCode: String?
    /// Seconds per phase of a finished file (convert, transcribe, summarise); nil on every other outcome (#4018).
    public var timings: PhaseTimings?

    public init(status: ProcessStatus, base: String, message: String,
                notePath: URL? = nil, transcriptPath: URL? = nil,
                detectedLanguages: String? = nil, dominantLanguageCode: String? = nil) {
        self.status = status; self.base = base; self.message = message
        self.notePath = notePath; self.transcriptPath = transcriptPath
        self.detectedLanguages = detectedLanguages
        self.dominantLanguageCode = dominantLanguageCode
    }
}

/// Injectable effects, mirroring the Python `deps` SimpleNamespace seam so the
/// pipeline can be tested without servers, ffmpeg, or AVFoundation.
/// Whether the on-device summariser can run right now, and if not, whether that
/// is a condition that resolves itself.
///
/// The distinction drives durability: a *transient* reason (Apple Intelligence
/// still downloading, or switched off and switchable back on) is the on-device
/// analogue of "server offline" and must DEFER, so the recording is retried.
/// An *unsupported* reason (wrong OS, ineligible Mac) can never resolve on this
/// machine, so it fails once with guidance to switch back to Ollama rather than
/// re-deferring forever.
public enum EmbeddedReadiness: Equatable {
    case ready
    case temporarilyUnavailable(String)
    case unsupported(String)
}

/// The outcome of picking a summariser: use one, defer (retry later), or fail.
enum SummariserChoice: Equatable {
    case use(SummariseTarget)
    case deferred(String)
    case unavailable(String)
}

/// Everything the summariser needs to know about the note besides the
/// transcript (Vikunja #2063, #2182). One value instead of a growing list
/// of closure parameters.
public struct NoteContext: Equatable, Sendable {
    public var noteOwner: String
    public var userSpeaker: String
    /// The owner's post-recording description of who was in the meeting, or nil.
    public var participants: String?
    /// When the recording started, when known (recorder filename or file date).
    public var meetingDate: Date?
    public var promptStyle: Prompt.Style
    /// The resolved note language (`NoteLanguage.resolve`): the meeting's
    /// detected language under "auto", or a fixed target code (Vikunja #2147,
    /// #2956). nil for "en" (default for any config predating the key), an
    /// unknown value, or no detection — the prompt is then byte-identical to
    /// before the feature. Honoured by Ollama and Gemma; Apple's on-device
    /// model gets it only for languages it reports supporting.
    public var noteLanguage: String?
    /// A one-off instruction from "Regenerate Note…" (Vikunja #2947); nil for
    /// every automatic run, which leaves the prompt byte-identical.
    public var customInstruction: String?
    /// The user's custom vocabulary (`transcribe.vocabulary`, Vikunja #2939).
    /// Empty (the default) leaves every prompt byte-identical.
    public var glossary: [String]
    /// The summary template resolved for this recording (Vikunja #2940), or nil
    /// for the stock section list - the prompt is then byte-identical to before.
    /// Honoured by Ollama, Gemma and Apple's on-device model.
    public var template: SummaryTemplate?
    /// Notes typed during the recording (Vikunja #2949); nil = prompt byte-identical.
    public var scratchpad: ScratchpadNotes?
    /// Calendar attendees the owner has not confirmed (#2946); empty = prompt byte-identical.
    public var calendarAttendees: [String]
    /// Sentences for the note's summary footer line (`NoteFooterLines`), e.g. why
    /// a template was chosen (1.19). Never part of the prompt.
    public var summaryNotes: [String] = []
    /// The recording stops while people were still talking (`TruncationCheck`, #4013). false = prompt byte-identical.
    public var recordingMayBeTruncated: Bool = false

    public init(noteOwner: String, userSpeaker: String, participants: String? = nil,
                meetingDate: Date? = nil, promptStyle: Prompt.Style = .classic,
                noteLanguage: String? = nil, customInstruction: String? = nil,
                glossary: [String] = [], template: SummaryTemplate? = nil,
                scratchpad: ScratchpadNotes? = nil, calendarAttendees: [String] = []) {
        self.calendarAttendees = calendarAttendees
        self.scratchpad = scratchpad
        self.customInstruction = customInstruction
        self.noteOwner = noteOwner; self.userSpeaker = userSpeaker
        self.participants = participants; self.meetingDate = meetingDate
        self.promptStyle = promptStyle; self.noteLanguage = noteLanguage
        self.glossary = glossary
        self.template = template
    }

    /// The full prompt for the Ollama path.
    public func prompt(transcript: String) -> String {
        Prompt.build(transcript: transcript, noteOwner: noteOwner, userSpeaker: userSpeaker,
                     participants: participants, style: promptStyle, meetingDate: meetingDate,
                     noteLanguage: noteLanguage, customInstruction: customInstruction, glossary: glossary, calendarAttendees: calendarAttendees,
                     template: template, scratchpad: scratchpad,
                     truncated: recordingMayBeTruncated)
    }
}

public struct PipelineDeps {
    public var convertToWav: (URL, URL) async throws -> Void
    public var transcribe: (URL, TranscribeConfig) async throws -> [String: Any]
    public var ollamaReachable: (String) async -> Bool
    /// Readiness of the on-device summariser. DistavoCore is dependency-free and
    /// cannot import DistavoEmbedded, so this comes in through the DI seam like
    /// `ollamaReachable`. Defaults to `.ready`, keeping every existing caller and
    /// test unchanged; the app layer wires it to `EmbeddedSummariser`.
    /// Keyed by the `EmbeddedSummaryModelCatalog` id being asked about, so each
    /// on-device model (Apple's, a downloaded Gemma) reports its own state.
    public var embeddedReadiness: (_ model: String) async -> EmbeddedReadiness
    public var summarise: (_ transcript: String, _ target: SummariseTarget,
                           _ options: SummariseOptions, _ context: NoteContext) async throws -> String
    /// Seconds of audio in a file, or nil when unknown. Consulted before
    /// transcribing so a too-short recording is set aside rather than failed
    /// (Vikunja #2185). Defaults to AVFoundation; tests inject a stub.
    public var audioDurationSeconds: (URL) async -> Double?
    /// Optional stage-boundary progress. Defaults to nil so tests and callers
    /// that don't care are unaffected (preserves the DI seam).
    public var onPhase: (@Sendable (ProcessingPhase) -> Void)?
    /// Calendar events overlapping `[start, end]` (Vikunja #2946). nil (the
    /// default) keeps the calendar feature inert and DistavoCore EventKit-free;
    /// the app layer wires it to EventKit, returning [] when access is missing.
    public var calendarLookup: ((_ start: Date, _ end: Date) async -> [CalendarCandidate])?
    /// When a recording actually started, from trustworthy evidence only: the
    /// built-in recorder's file name or the media's embedded creation date -
    /// never the filesystem creation/modification date (Vikunja #2946).
    public var recordingStart: (URL) async -> Date?
    /// The container's embedded creation date (when the recording ENDED, usually UTC), for dating a
    /// dropped file's note when its name carries no stamp (Vikunja #4018). Defaults to AVAsset metadata.
    public var containerCreationDate: (URL) async -> Date?
    /// The source's left/right samples for `transcribe.channel_speakers` (#6353); nil when it is not stereo or
    /// unreadable. Only consulted when that flag is on.
    public var stereoChannels: (URL) async -> StereoChannels?

    public init(
        convertToWav: @escaping (URL, URL) async throws -> Void,
        transcribe: @escaping (URL, TranscribeConfig) async throws -> [String: Any],
        ollamaReachable: @escaping (String) async -> Bool,
        summarise: @escaping (String, SummariseTarget, SummariseOptions, NoteContext) async throws -> String,
        onPhase: (@Sendable (ProcessingPhase) -> Void)? = nil,
        embeddedReadiness: @escaping (String) async -> EmbeddedReadiness = { _ in .ready },
        audioDurationSeconds: @escaping (URL) async -> Double? = { AudioConverter.durationSeconds(of: $0) },
        calendarLookup: ((Date, Date) async -> [CalendarCandidate])? = nil,
        recordingStart: @escaping (URL) async -> Date? = { Pipeline.recordingStartEvidenceSync($0) },
        containerCreationDate: @escaping (URL) async -> Date? = { Pipeline.creationDateMetadataSync($0) },
        stereoChannels: @escaping (URL) async -> StereoChannels? = { StereoChannels.read(from: $0) }
    ) {
        self.stereoChannels = stereoChannels
        self.containerCreationDate = containerCreationDate
        self.calendarLookup = calendarLookup
        self.recordingStart = recordingStart
        self.convertToWav = convertToWav
        self.transcribe = transcribe
        self.ollamaReachable = ollamaReachable
        self.summarise = summarise
        self.onPhase = onPhase
        self.embeddedReadiness = embeddedReadiness
        self.audioDurationSeconds = audioDurationSeconds
    }

    /// Real dependencies wired to AVFoundation + the HTTP clients.
    public static func live() -> PipelineDeps {
        let whisper = WhisperXClient()
        let ollama = OllamaClient()
        return PipelineDeps(
            convertToWav: { try await AudioConverter.convertToWav(source: $0, dest: $1) },
            transcribe: { try await whisper.transcribe(wavURL: $0, config: $1) },
            ollamaReachable: { await ollama.reachable($0) },
            summarise: { transcript, target, options, context in
                // DistavoCore is dependency-free, so it can only serve the Ollama
                // target. The app layer (AppPipelineDeps) wraps this to route
                // `.embedded` at the FoundationModels engine.
                guard case let .ollama(url, model) = target else {
                    throw OllamaError("On-device summarisation is not available in this build.")
                }
                return try await ollama.generate(url: url, model: model,
                                                 prompt: context.prompt(transcript: transcript), options: options)
            })
    }
}

/// A one-off run of a recording with a specific engine/model and language,
/// chosen by the user in "Process a recording with…" (Vikunja #2159). The
/// note lands beside the normal one under `<base>@<suffix>.md`, with its own
/// markers, so it never collides with (or pre-empts) the automatic run of
/// the same file; the source recording is never compacted on a variant run.
public struct ProcessVariant: Equatable, Sendable {
    /// Filename-safe tag, e.g. "bsc-los-ca" — see `suffix(model:language:)`.
    public let suffix: String
    /// The transcribe settings to use instead of the config's.
    public let transcribe: TranscribeConfig
    /// An Ollama target to summarise with instead of the config's normal
    /// selection (`Pipeline.chooseSummariser`) — used by the
    /// `retrySummariseBigger` `WhenDoneAction` (Vikunja #2205) to force
    /// `SummariseConfig.biggerModel` regardless of which backend/reachability
    /// the automatic run picked. nil (every other caller) keeps the normal
    /// selection untouched.
    public let summariseOverride: OllamaTarget?

    public init(suffix: String, transcribe: TranscribeConfig, summariseOverride: OllamaTarget? = nil) {
        self.suffix = DistavoState.sanitizeJoined(suffix)
        self.transcribe = transcribe
        self.summariseOverride = summariseOverride
    }

    /// "<model id>-<language code or auto>", sanitised for a filename.
    public static func suffix(model: String, language: String) -> String {
        let lang = language.isEmpty ? "auto" : language
        return DistavoState.sanitizeJoined("\(model)-\(lang)")
    }

    /// The variant's base name for `base`: `@` never survives
    /// `DistavoState.baseFor`'s sanitising, so a variant base can never be a
    /// real recording's base.
    public func base(for base: String) -> String { "\(base)@\(suffix)" }
}

/// Port of `meeting_pipeline/pipeline.py`.
public enum Pipeline {

    /// Choose where to summarise, or signal deferral.
    ///
    /// Both backends can defer, for the same reason: a dependency that is
    /// temporarily absent but will come back. For Ollama that is an unreachable
    /// server; for the embedded engine it is Apple Intelligence still
    /// downloading its model, or being switched off — genuinely transient
    /// conditions that resolve in minutes. Returning `.use(.embedded)`
    /// regardless meant summarise threw, processOne marked the base FAILED, and
    /// `DistavoState.iterPending` then skipped it forever, so a recording was
    /// never retried for a condition that fixed itself.
    ///
    /// A reason that can never resolve on this Mac (unsupported OS, ineligible
    /// hardware) still fails, so the user is told to switch back to Ollama
    /// instead of the recording sitting deferred indefinitely.
    ///
    /// `summarise.embeddedEnabled` gates the embedded backend as a kill switch:
    /// when it is false, a config asking for "embedded" falls through to the
    /// normal Ollama selection rather than failing.
    static func chooseSummariser(
        _ config: Config, reachable: (String) async -> Bool,
        embeddedReadiness: (String) async -> EmbeddedReadiness = { _ in .ready }
    ) async -> SummariserChoice {
        let s = config.summarise
        if s.backend == "embedded" && s.embeddedEnabled {
            // An unknown id resolves to Apple's model, so readiness is only ever
            // asked about a catalogue entry.
            let model = EmbeddedSummaryModelCatalog.model(id: s.embeddedModel).id
            switch await embeddedReadiness(model) {
            case .ready: return .use(.embedded(model: model))
            case .temporarilyUnavailable(let why): return .deferred(why)
            case .unsupported(let why): return .unavailable(why)
            }
        }
        if s.backend == "local" { return .use(.ollama(url: s.local.url, model: s.local.model)) }
        if await reachable(s.server.url) {
            return .use(.ollama(url: s.server.url, model: s.server.model))
        }
        if s.allowLocalFallback { return .use(.ollama(url: s.local.url, model: s.local.model)) }
        return .deferred("Server Ollama offline; local fallback not allowed yet")
    }

    public static func processOne(
        path: URL, config: Config, deps: PipelineDeps,
        stableChecks: Int = 3, stableDelay: Double = 2.0,
        variant: ProcessVariant? = nil
    ) async -> ProcessResult {
        let recordingsDir = Config.resolvePath(config.recordingsDir)
        let sourceBase = DistavoState.baseFor(recordingsDir: recordingsDir, path: path)
        let base = variant?.base(for: sourceBase) ?? sourceBase
        let notesDir = Config.resolvePath(config.notesDir)
        let workDir = Config.resolvePath(config.workDir)

        let state: DistavoState.Store
        do {
            state = try DistavoState.Store(
                stateDir: workDir.appendingPathComponent(".state"), notesDir: notesDir)
        } catch {
            return ProcessResult(status: .failed, base: base,
                                 message: "state init failed: \(error.localizedDescription)")
        }

        if state.isDone(base) {
            return ProcessResult(status: .skipped, base: base,
                                 message: "already processed", notePath: state.notePath(base))
        }
        if !DistavoState.waitUntilStable(path, checks: stableChecks, delay: stableDelay) {
            return ProcessResult(status: .skipped, base: base, message: "file still changing")
        }
        if state.isProcessing(base) {
            return ProcessResult(status: .skipped, base: base, message: "already being processed")
        }

        // Too short to be a meeting? Decide from the source file when
        // AVFoundation can read it directly (WAV/M4A/…), otherwise from the
        // converted WAV below. Nothing is written yet, so this is cheap — and
        // it comes BEFORE the summariser choice: a file that will be set aside
        // must not sit deferred behind an offline Ollama instead.
        let minSeconds = Double(max(0, config.minRecordingSeconds))
        if minSeconds > 0, let seconds = await deps.audioDurationSeconds(path), seconds < minSeconds {
            return setAsideTooShort(state: state, base: base, source: path, seconds: seconds, minimum: minSeconds)
        }

        let target: SummariseTarget
        if let override = variant?.summariseOverride {
            // A forced re-summarise (retryTranscribeBigger passes no override;
            // retrySummariseBigger does) bypasses reachability/deferral: the
            // caller only queues this once the normal run has already
            // succeeded, so there is nothing to defer back to.
            target = .ollama(url: override.url, model: override.model)
        } else {
            switch await chooseSummariser(config, reachable: deps.ollamaReachable,
                                          embeddedReadiness: deps.embeddedReadiness) {
            case .use(let chosen):
                target = chosen
            case .deferred(let why):
                return ProcessResult(status: .deferredNeedLocal, base: base, message: why)
            case .unavailable(let why):
                // Permanent on this Mac — record it so the user sees a note-less
                // recording explained, instead of it being retried every scan.
                state.markFailed(base, why)
                return ProcessResult(status: .failed, base: base, message: why)
            }
        }

        state.markProcessing(base)
        try? FileManager.default.createDirectory(at: notesDir, withIntermediateDirectories: true)
        let notePath = state.notePath(base)

        // The owner's post-recording description of the meeting, if any
        // (keyed by the recording, so a variant run gets it too): its speaker
        // count is authoritative for diarisation, and the participants text
        // goes into the prompt.
        // Calendar event for this recording (#2946); nil when off / no match.
        let calendarMatch = await CalendarLookup.resolve(
            path: path, sourceBase: sourceBase, workDir: workDir, config: config, deps: deps)
        // Same call captured twice (#4014): note a time record for this recording, link a twin already seen
        // and reuse its sheet when this one has none. Needs trustworthy time evidence; nil means no record.
        // Only when `notes.link_duplicate_calls` is on (off for configs that predate it): off writes no sidecar,
        // no footer line and copies no sheet.
        var alsoCaptured: AlsoCaptured?
        if variant == nil, config.notes.linkDuplicateCalls {
            // One await per statement: two awaited dependency closures in one condition list aborted the test
            // process on the macOS 26 runtime ("freed pointer was not the last allocation", CI 2026-11-14).
            let time = await deps.recordingStart(path)
            let seconds = time == nil ? nil : await deps.audioDurationSeconds(path)
            if let time, let seconds, seconds > 0 {
                alsoCaptured = DuplicateCallLink.register(
                    CallRecord(base: sourceBase, time: time, durationSeconds: seconds,
                               isLiveCapture: exactRecorderNameDate(path) != nil), workDir: workDir)
            }
        }
        let hints = SpeakerHints.load(workDir: workDir, base: sourceBase, source: path)
        var transcribeConfig = variant?.transcribe ?? config.transcribe
        transcribeConfig.numSpeakers = SpeakerHints.reconciledCount(
            hintCount: hints?.count, participants: hints?.participants, configured: transcribeConfig.numSpeakers)
        // This meeting's own terms come first, then the global vocabulary (#3584); the enabled replacement
        // packs follow the user's own rules.
        // Names from the participants line are seeded too (#3950).
        // Then the role packs of the participants line (accountant -> UK tax terms, RoleTermPacks).
        // Role terms go AFTER the user's global vocabulary (the prompt budget trims from the end) and never feed
        // the fuzzy post-pass, which rewrites words: only terms the owner typed or named are snapped.
        // The owner's own name (full and first, #6772): a misheard "Marc" must not become a second person. It always
        // feeds the summary glossary and the fuzzy post-pass, but joins the TRANSCRIBER vocabulary only when that
        // already has terms: a vocabulary prompt triggers #3579 (BSC Catalan chunks collapse), so the owner never
        // creates one. Unset owner adds nothing.
        let meetingTerms = (hints?.terms ?? []) + (hints?.participantTerms ?? [])
        // English packs only for an English or unpinned meeting (drive review C): never into a Catalan vocabulary prompt.
        let roleTerms = hints?.roleTerms(
            configuredLanguage: transcribeConfig.language,
            override: LanguageOverride.load(workDir: workDir, base: LanguageOverride.sourceBase(from: sourceBase))) ?? []
        let ownerTerms = OwnerIdentity.terms(noteOwner: config.noteOwner)
        let transcriberHasTerms = !Vocabulary.normalisedTerms(meetingTerms + transcribeConfig.vocabulary).isEmpty
        let transcriberTerms = meetingTerms + (transcriberHasTerms ? ownerTerms : [])
        if !transcriberTerms.isEmpty {
            transcribeConfig.vocabulary = Vocabulary.normalisedTerms(transcriberTerms + transcribeConfig.vocabulary)
        }
        let fuzzyTerms = Vocabulary.normalisedTerms(transcribeConfig.vocabulary + ownerTerms)
        var summaryGlossary = fuzzyTerms   // what the summary prompt's spelling aid lists
        if !roleTerms.isEmpty {
            transcribeConfig.vocabulary = Vocabulary.normalisedTerms(transcribeConfig.vocabulary + roleTerms)
            summaryGlossary = Vocabulary.normalisedTerms(summaryGlossary + roleTerms)
        }
        transcribeConfig.replacements = transcribeConfig.effectiveReplacements
        // Participants stay exactly what the owner stated; unconfirmed calendar names ride in their own block.
        let participants = hints?.participants?.trimmingCharacters(in: .whitespacesAndNewlines)
        let calendarAttendees = CalendarLookup.promptAttendees(participants: participants, match: calendarMatch, config: config)

        do {
            // A re-run must never leave the previous run's timed transcript
            // behind (#2943): export would pair it with the new note.
            try? FileManager.default.removeItem(at: TranscriptSegments.url(workDir: workDir, base: base))
            TranscriptEditStore.removeOriginals(workDir: workDir, base: base)   // #2951: edits belonged to the old transcript
            let wavPath = workDir.appendingPathComponent("\(base).wav")
            var timings = PhaseTimings()   // #4018: one line per file saying where the time went
            var phaseStart = Date()
            func lap(_ name: String) { timings.add(name, seconds: Date().timeIntervalSince(phaseStart)); phaseStart = Date() }
            func withTimings(_ r: ProcessResult) -> ProcessResult {
                // Every `.done` exit comes through here: the long-recording part caches (#6759) have served.
                if r.status == .done { LongRecording.removeCaches(workDir: workDir, base: base) }
                lap("summarise+note")
                print("[Distavo] " + timings.logLine)
                var r = r; r.timings = timings; return r
            }
            deps.onPhase?(.converting)

            // A prior attempt (e.g. one that later hit a RetryableDependencyError
            // at the transcribe stage) may have already produced a good WAV for
            // this exact source file — re-converting it is wasted work on every
            // retry of a slow AVFoundation pass. Only trust it when it is newer
            // than the source recording, so an edited/re-recorded file still
            // gets a fresh conversion.
            if !wavIsFresh(wavPath: wavPath, sourcePath: path) {
                do { try await deps.convertToWav(path, wavPath); state.clearTransientConvertFailures(base) } catch {
                    // #5283: the same conversion failure twice is terminal, not a retry per launch.
                    // Drive d (#1793): a transient one (never a cancellation) is terminal after a run of five.
                    let size = (try? FileManager.default.attributesOfItem(atPath: path.path)[.size] as? Int) ?? nil
                    let message = cleanMessage(error)
                    // A half-written WAV is newer than the source: `wavIsFresh` would trust it on the retry and
                    // transcribe truncated audio (and no second failure would ever be counted).
                    try? FileManager.default.removeItem(at: wavPath)
                    let terminal: Bool
                    if error is CancellationError || Self.isMachineLevelConvertFailure(error) {
                        // Cancelled, or the machine's problem (disk full, permission): never the file's fault, so it
                        // is never counted towards a terminal state however often it recurs.
                        terminal = false
                    } else if Self.isTransientConvertFailure(error) {
                        terminal = state.recordTransientConvertFailure(base, message: message, fileSize: size)
                    } else {
                        terminal = state.recordConvertFailure(base, message: message, fileSize: size)
                    }
                    if terminal {
                        // #5477: the unreadable list is the single home of a terminal file. A `.failed` marker too
                        // would show it in both menu lists, and "Retry failed" would clear only that one.
                        state.clearProcessing(base); state.clearDeferred(base)
                        return ProcessResult(status: .failed, base: base,
                                             message: message + " (not retried again; Move to Bin or replace the file)")
                    }
                    // Retryable (the machine's problem, or transient under the cap): DEFER with backoff so the scan
                    // retries it. A `.failed` marker is only cleared by the user's Retry, so a full disk or an
                    // offline volume used to leave the file failed for good (h-chain review 2026-11-09).
                    if !(error is CancellationError),
                       Self.isMachineLevelConvertFailure(error) || Self.isTransientConvertFailure(error) {
                        throw RetryableDependencyError(message + " - will retry")
                    }
                    throw error
                }
            }
            // Second chance for the length check: containers AVFoundation
            // could not measure directly (video files) are measurable now.
            if minSeconds > 0, let seconds = await deps.audioDurationSeconds(wavPath), seconds < minSeconds {
                return setAsideTooShort(state: state, base: base, source: path, seconds: seconds, minimum: minSeconds)
            }

            lap("convert")
            deps.onPhase?(.transcribing)
            // #6759: a long recording goes to the engine in bounded parts (memory and CoreML buffers grew with the
            // length of the file; 4 h 21 min aborted the app), then the parts are stitched back together.
            let longParts = LongRecording.plan(wav: wavPath)
            var result = longParts.isEmpty
                ? try await deps.transcribe(wavPath, transcribeConfig)
                : try await LongRecording.transcribe(wav: wavPath, parts: longParts, base: base, workDir: workDir,
                                                     config: transcribeConfig, transcribe: deps.transcribe)
            lap("transcribe")
            var channelLabelled = false   // owner is SPEAKER_00 by construction (ChannelSpeakerLabeller)
            var stereoNeeded = false      // a stereo original that a reprocess would read again
            // #6353: speakers from the stereo channels when the flag is on and both sides carry signal; any
            // other case (mono source, a silent channel, no word timings) keeps the engine's own labels.
            // Two sides cannot describe a call of three or more people (the remote side is several voices): then the
            // diariser's labels stay. Auto (0) counts the people the participants sheet names.
            let expectedPeople = max(transcribeConfig.numSpeakers, SpeakerHints.suggestedCount(hints?.participants) ?? 0)
            if transcribeConfig.channelSpeakers, expectedPeople <= 2, let ch = await deps.stereoChannels(path) {
                stereoNeeded = true
                if let relabelled = ChannelSpeakerLabeller.relabel(result: result, channels: ch) {
                    result = relabelled
                    channelLabelled = true
                }
            }
            // #3950: the vocabulary cannot reach an engine without a prompt (Parakeet): snap near-miss spellings in
            // the finished text instead. The rules ride the ordinary replacement map, after the user's own.
            if transcribeConfig.fuzzyVocabulary, !fuzzyTerms.isEmpty {
                let text = TranscriptCleaner.segments(from: result).map(\.text).joined(separator: " ")
                transcribeConfig.replacements += FuzzyVocabulary.rules(terms: fuzzyTerms, text: text)
            }
            let detectedLanguages = detectedLanguages(from: result)
            // Computed unconditionally (unlike `noteLanguage` below, which
            // only uses it for "auto") so `ProcessResult`
            // always reports it when available — `retryTranscribeBigger`
            // needs it regardless of the note-language setting (#2205).
            let dominantCode = dominantLanguageCode(from: result)

            let cleanedOnce = TranscriptCleaner.clean(
                TranscriptCleaner.segments(from: result), replacements: transcribeConfig.replacements)
            // Safety net (#3951): a mis-heard slur never reaches the transcript, segments or summary prompt.
            let guarded = OffensiveWordGuard.apply(cleanedOnce)
            let clean = guarded.text
            GuardReport.store(guarded.flagged, workDir: workDir, base: base)
            if clean.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                LongRecording.removeCaches(workDir: workDir, base: base)   // nothing in them worth resuming
                state.markFailed(base, "empty transcript")
                return ProcessResult(status: .failed, base: base, message: "empty transcript")
            }
            // Which of the user's global terms were really heard (Settings shows "last used", #3584).
            VocabularyUsage.record(terms: config.transcribe.vocabulary, transcript: clean, workDir: workDir)
            // A different language or different people than last time: offer to clear unheard terms (#3584).
            VocabularyClearOffer.observe(language: dominantCode, participants: participants,
                                         terms: config.transcribe.vocabulary, transcript: clean, workDir: workDir)
            let transcriptPath = workDir.appendingPathComponent("\(base).transcript.clean.txt")
            try? (clean + "\n").write(to: transcriptPath, atomically: true, encoding: .utf8)
            // For "Regenerate Note…" (#2947): keep the detected language beside it.
            TranscriptMeta.store(dominant: dominantCode, ownerSpeaker: channelLabelled ? "SPEAKER_00" : nil,
                                 workDir: workDir, base: base)
            // Timed twin of the clean transcript for exports/viewer (#2943).
            // Best-effort: a failure to write it must never fail the recording.
            var timedForNote: TranscriptSegments?   // tracked terms / duration (#2954)
            if var timed = TranscriptSegments(whisperXResult: result) {
                // Same replacement map as the clean transcript, so SRT/DOCX/PDF
                // exports spell the term like the note does (Vikunja #2939).
                let compiled = CompiledReplacements(transcribeConfig.replacements)
                if !compiled.isEmpty { timed = timed.applying(compiled) }
                if guarded.flagged > 0 { timed = timed.guardedAgainstOffensiveWords().0 }
                timedForNote = timed
                do { try timed.save(workDir: workDir, base: base) }
                catch { print("[Distavo] could not save \(base).segments.json: \(error.localizedDescription)") }
            }

            deps.onPhase?(.summarising)
            // The note language (Vikunja #2147, #2956): a per-recording
            // override (`<base>.language.json`) beats `summarise.note_language`,
            // which is "en" (default: nil, prompt untouched), "auto" (the
            // meeting's dominant detected language) or a fixed language code.
            // Unknown values behave like "en". See `NoteLanguage.resolve`.
            // With no detection (WhisperX, or a spoken language fixed by the
            // owner) "auto" falls back to that fixed spoken language.
            let noteLanguage = resolveNoteLanguage(
                config: config, workDir: workDir, base: base, dominantCode: dominantCode)
            // Summary template (#2940): recording sidecar > recordings subfolder > Settings; "auto" (#3582)
            // picks from the participants and the start of the transcript.
            let resolvedTemplate = SummaryTemplateCatalog.resolveWithReason(
                config: config,
                folder: SummaryTemplateCatalog.folder(of: path, in: recordingsDir),
                sidecarID: LanguageOverride.load(
                    workDir: workDir, base: LanguageOverride.sourceBase(from: base))?.template,
                participants: participants, transcript: clean)
            // The template actually used, by name, so the log answers "why is this note shaped like that" (#6667).
            print("[Distavo] " + StopSheetTemplate.logLine(
                base: base, template: resolvedTemplate.template, autoNote: resolvedTemplate.note))
            // A plain var, not a `let` initialised in an if/else with an await in one branch: that shape aborted the
            // test process on the macOS 26 runtime with Xcode 26.4-26.6 ("freed pointer was not the last allocation").
            var noteDate = calendarMatch?.recordingStart
            if noteDate == nil { noteDate = Pipeline.noteStartFromName(path) }
            if noteDate == nil {
                // The awaits stay in processOne (see `noteStart(for:created:duration:)`).
                let created = await deps.containerCreationDate(path)
                let duration = created == nil ? nil : await deps.audioDurationSeconds(path)
                noteDate = Pipeline.noteStart(for: path, created: created, duration: duration)
            }
            var context = NoteContext(
                noteOwner: config.noteOwner,
                // Channel labels put the owner (left, microphone) on SPEAKER_00 whatever label the owner typed
                // for the diariser's numbering.
                userSpeaker: channelLabelled ? "SPEAKER_00" : OwnerSpeakerLabel.effective(configured: config.userSpeaker, transcript: clean),   // #3857
                participants: participants, meetingDate: noteDate,
                promptStyle: config.summarise.promptStyle, noteLanguage: noteLanguage,
                // Title/tags request (#2954); nil unless auto_title/auto_tags is on.
                customInstruction: OwnerIdentity.merged(nil, noteOwner: config.noteOwner, notes: config.notes),   // #6772 owner rule + #2954
                glossary: summaryGlossary,
                // Summary template (#2940): recording sidecar > recordings subfolder > Settings.
                // Action items (#2941) rewrite its sections when switched on.
                template: ActionItemsPrompt.effectiveTemplate(resolvedTemplate.template,
                    style: config.summarise.promptStyle, enabled: config.summarise.actionItems),
                scratchpad: ScratchpadNotes.load(workDir: workDir, base: sourceBase),   // #2949
                calendarAttendees: calendarAttendees)   // #2946
            if let note = resolvedTemplate.note { context.summaryNotes.append(note) }   // #3582
            // #6759: "transcribed in N parts" and any part that is missing, whatever engine ran.
            context.summaryNotes += (result[LongRecording.notesKey] as? [String]) ?? []
            // Key moments (#2950) are the owner's own live markers: they belong in every note, also the
            // transcript-only one below.
            let keyMoments = RecordingBookmarks.load(workDir: workDir, base: sourceBase)?.noteSection(
                segments: TranscriptSegments.load(workDir: workDir, base: base)) ?? ""   // #2950
            // #4015 (opt-in): film/TV audio or a solo memo is not a meeting. Not-a-meeting gets a short transcript-only
            // note; one voice gets the memo template. A participants sheet always means "meeting".
            if config.summarise.nonMeetingGuard {
                let sheet = !(participants ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                switch MeetingShapeGate.assess(segments: TranscriptCleaner.segments(from: result), hasParticipantsSheet: sheet) {
                case .meeting: break
                case .soloMemo:
                    context.template = ActionItemsPrompt.effectiveTemplate(
                        MeetingShapeGate.memoTemplate, style: config.summarise.promptStyle,
                        enabled: config.summarise.actionItems)
                case .notAMeeting(let reason):
                    let note = composeNote(
                        body: Self.keepingLiveCapture(
                            MeetingShapeGate.notAMeetingNote(reason: reason, transcript: clean),
                            scratchpad: context.scratchpad, keyMoments: keyMoments),
                        footer: "", meta: nil,
                        config: config, context: context, sourceName: path.lastPathComponent, timed: timedForNote,
                        cleanTranscript: clean, dominantCode: dominantCode,
                        existingNote: try? String(contentsOf: notePath, encoding: .utf8), calendar: calendarMatch)
                    try note.write(to: notePath, atomically: true, encoding: .utf8)
                    state.markDone(base)
                    return withTimings(ProcessResult(status: .done, base: base,
                                         message: "note written (transcript only: does not look like a meeting: \(reason))",
                                         notePath: notePath, transcriptPath: transcriptPath,
                                         detectedLanguages: detectedLanguages, dominantLanguageCode: dominantCode))
                }
            }
            // #4013: a recording that stops mid-conversation is flagged, not summarised as complete.
            if let timed = timedForNote, let audio = await deps.audioDurationSeconds(path),
               TruncationCheck.isTruncated(segments: timed.segments, audioSeconds: audio) {
                context.recordingMayBeTruncated = true
                context.summaryNotes.append(TruncationCheck.banner)
                print("[Distavo] " + TruncationCheck.logLine(lastSegmentEnd: timed.segments.last?.end ?? 0, audioSeconds: audio))
            }
            // One summarise attempt: run the model, strip a leaked
            // facts-first working preamble (Vikunja #2203), append the
            // footer, and validate.
            var noteMeta: NoteMeta.Extracted?       // the model's title/tags (#2954)
            var noteBody = "", noteFooter = ""
            var languageRetried = false             // #3585: the one retry for a note in the wrong language
            var summaryOptions = config.summarise.options   // #4011: stiffened for the one retry after a repetition collapse
            var summariseInput: String?             // #4011: the merged part notes on the chunked third attempt
            func summariseAttempt() async throws -> (text: String, failures: [String]) {
                let raw = try await deps.summarise(summariseInput ?? clean, target, summaryOptions, context)
                // A rare edge case (the ledger only existed in the discarded
                // preamble): print rather than writing to the real
                // ActivityLog file, so a unit test exercising it never
                // touches disk outside its own temp dirs.
                var cleaned = SummaryCleaner.stripLeakedWorkingSteps(raw) { message in
                    print("[Distavo] \(message)")
                }
                // The model's title/tags lines leave the body first (#2954).
                if config.notes.asksModelForMetadata {
                    noteMeta = NoteMeta.extract(from: cleaned)
                    cleaned = noteMeta?.body ?? cleaned
                }
                // Typed scratchpad lines (#2949) reach the note even if the model ignored them.
                if let pad = context.scratchpad { cleaned = pad.ensureHighlights(in: cleaned) }
                // Post-summary checks shared with regenerate (1.19): may rewrite the text and add footer notes.
                var checked = SummaryChecks.apply(summary: cleaned, transcript: clean, context: context,
                                                applyCorrections: config.summarise.applyCorrections)
                cleaned = checked.text
                // A retry that still came back in the wrong language says so in the footer (#3585).
                if languageRetried, let requested = context.noteLanguage,
                   let note = NoteLanguageCheck.footerNote(requested: requested, text: cleaned) {
                    checked.notes.append(note)
                }
                // Key moments (#2950) are appended after the model and excluded from validation.
                // Note order (see `NoteAssembly`): frontmatter, body with Highlights, Key moments,
                // Tracked terms, provenance footer. `noteBody` is the body INCLUDING Key moments.
                let footer = NoteFooterLines.footer(
                    provenance: provenanceFooter(from: result),
                    summaryNotes: checked.notes + (alsoCaptured.map {
                        [DuplicateCallDetector.alsoCapturedLine(otherBase: $0.otherBase, isPrimary: $0.isPrimary)]
                    } ?? []))
                let withMoments = RecordingBookmarks.appending(keyMoments, to: cleaned)
                (noteBody, noteFooter) = (withMoments, footer)
                return (withMoments + footer, checked.failures + SummaryValidator.validate(cleaned + footer))
            }

            // Part notes for `parts`, merged into one input for the final pass; nil when no part produced a usable
            // note. A part that fails or is rejected is left out (logged); a retryable error or a cancel stops all.
            func summariseInParts(_ parts: [String]) async throws -> String? {
                try await Pipeline.summariseInParts(parts, target: target, options: summaryOptions, context: context,
                                                    summarise: deps.summarise)
            }

            // #6759: a transcript longer than the Ollama context window is summarised part by part and the part
            // notes merged; sent whole, Ollama silently drops the start of the prompt. The on-device engines plan
            // their own chunks (`SummaryGenerator`), so only the Ollama target is checked.
            if let long = try await Pipeline.longTranscriptInput(clean, target: target, options: summaryOptions,
                                                                 context: context, summarise: deps.summarise) {
                summariseInput = long.input
                context.summaryNotes.append(Pipeline.partedSummaryNote(parts: long.parts))
            }
            var (noteText, failures) = try await summariseAttempt()
            // A truncated/empty response gets one retry with the same
            // prompt — Ollama occasionally cuts a response short with no
            // thrown error (a genuinely-thrown empty response already fails
            // via the catch clause below and is unaffected by this). A
            // structurally broken response (repetition collapse, overlong)
            // is very unlikely to be fixed by asking again, so those kinds
            // keep failing immediately as before.
            if isRetryableTruncation(failures) {
                (noteText, failures) = try await summariseAttempt()
            }
            // A repetition collapse (a loop the guard rightly rejects) gets ONE retry with a firmer
            // repeat penalty and another seed (#4011); the same options would loop the same way.
            var collapsed = failures.contains { $0.contains("repetition collapse") }
            if collapsed {
                summaryOptions = Pipeline.stiffened(summaryOptions)
                (noteText, failures) = try await summariseAttempt()
                collapsed = failures.contains { $0.contains("repetition collapse") }
            }
            // A long take that still loops is summarised part by part, then the part notes are merged (#4011):
            // each part is short enough that the model has no room to loop on one quote.
            if collapsed {
                let parts = Pipeline.collapseParts(of: clean)
                if parts.count >= 2 {
                    if let merged = try await summariseInParts(parts) {
                        // Kept set through the language check below; every path that still fails returns the fallback.
                        summariseInput = merged
                        do {
                            (noteText, failures) = try await summariseAttempt()
                        } catch is CancellationError { throw CancellationError()
                        } catch let retry as RetryableDependencyError { throw retry
                        } catch { failures = ["merge of part notes failed: \(error.localizedDescription)"] }
                        // Any failure of the merge keeps the transcript-only note, never a stuck `.failed`.
                        collapsed = !failures.isEmpty
                    }
                }
            }
            // Still looping: keep the work. A transcript-only note that says why beats no note and a stuck
            // `.failed` marker; Regenerate can fill the summary in later. The rejected text stays quarantined.
            if collapsed {
                let quarantine = workDir.appendingPathComponent("\(base).failed-summary.md")
                let saveError = Pipeline.quarantine(noteText, at: quarantine, workDir: workDir)
                let reason = failures.joined(separator: "; ")
                let fallback = composeNote(
                    body: Self.keepingLiveCapture(   // Quick Notes and Key moments survive a rejected summary too
                        Pipeline.transcriptOnlyNote(reason: reason, transcript: clean),
                        scratchpad: context.scratchpad, keyMoments: keyMoments),
                    footer: "", meta: nil,
                    config: config, context: context, sourceName: path.lastPathComponent, timed: timedForNote,
                    cleanTranscript: clean, dominantCode: dominantCode,
                    existingNote: try? String(contentsOf: notePath, encoding: .utf8), calendar: calendarMatch)
                try fallback.write(to: notePath, atomically: true, encoding: .utf8)
                state.markDone(base)
                return withTimings(ProcessResult(status: .done, base: base,
                                     message: "note written (transcript only: summary rejected: \(reason))"
                                        + (saveError.map { "; rejected summary could not be saved: \($0)" } ?? ""),
                                     notePath: notePath, transcriptPath: transcriptPath,
                                     detectedLanguages: detectedLanguages, dominantLanguageCode: dominantCode))
            }
            // A Catalan/Spanish note that came back in another language gets one retry with the
            // language stated again (#3585). The first note is kept if the retry is rejected.
            if failures.isEmpty, let requested = context.noteLanguage,
               NoteLanguageCheck.ignored(requested: requested, in: noteBody) {
                let keep = (noteText, noteBody, noteFooter, noteMeta, context.customInstruction)
                languageRetried = true
                context.customInstruction = [context.customInstruction, NoteLanguageCheck.retryInstruction(requested: requested)]
                    .compactMap { $0 }.joined(separator: "\n")
                let (retryText, retryFailures) = try await summariseAttempt()
                context.customInstruction = keep.4
                if retryFailures.isEmpty { (noteText, failures) = (retryText, retryFailures) }
                else { (noteText, noteBody, noteFooter, noteMeta) = (keep.0, keep.1, keep.2, keep.3) }
            }
            if !failures.isEmpty {
                // Quarantine (Vikunja #2669): a summary that fails validation
                // (repetition collapse, empty, overlong, cut short — after the
                // one truncation retry above) is NOT a note. Keep it in the
                // work dir for inspection rather than in the notes folder,
                // where it looks real and "open when done" could show it.
                // (A seed-based re-roll of a collapsed summary is deliberately
                // out of scope here.) The `.failed` marker is unchanged, and
                // `notePath` stays nil so nothing in the UI can open it.
                let quarantine = workDir.appendingPathComponent("\(base).failed-summary.md")
                let saveError = Pipeline.quarantine(noteText, at: quarantine, workDir: workDir)
                // The reason (validator text names it) is what the menu shows.
                // Name the file so the reason in the menu/log says where the rejected text went,
                // or says it could not be kept (#4374: never claim a file that was not written).
                let message = "summary rejected: " + failures.joined(separator: "; ")
                    + (saveError.map { " (rejected summary could not be saved: \($0))" } ?? " (kept at \(quarantine.path))")
                state.markFailed(base, message)
                return ProcessResult(status: .failed, base: base, message: message,
                                     transcriptPath: transcriptPath,
                                     detectedLanguages: detectedLanguages, dominantLanguageCode: dominantCode)
            }
            // Frontmatter / tracked terms (#2954); the unchanged text with default settings.
            noteText = composeNote(
                body: noteBody, footer: noteFooter, meta: noteMeta, config: config, context: context,
                sourceName: path.lastPathComponent, timed: timedForNote, cleanTranscript: clean,
                dominantCode: dominantCode,
                existingNote: try? String(contentsOf: notePath, encoding: .utf8), calendar: calendarMatch)
            try noteText.write(to: notePath, atomically: true, encoding: .utf8)
            rememberTitle(noteMeta, config: config, workDir: workDir, base: base, calendar: calendarMatch)   // #2954, #2946
            state.markDone(base)
            var message = "note written"
            // Compaction makes the take mono; with channel speakers on, a reprocess needs the stereo original.
            if config.compactRecordingsAfterNote, variant == nil, !stereoNeeded,
               let compacted = compactRecording(source: path, compactWav: wavPath) {
                message += "; recording compacted \(compacted)"
            }
            return withTimings(ProcessResult(status: .done, base: base, message: message,
                                 notePath: notePath, transcriptPath: transcriptPath,
                                 detectedLanguages: detectedLanguages, dominantLanguageCode: dominantCode))
        } catch let retry as RetryableDependencyError {

            // I2: grow the wait with each consecutive deferral (60 s, 120 s,
            // 240 s, … capped at 1800 s) instead of retrying on every scan —
            // a dependency that stays offline for a while (or a model folder
            // that keeps failing its manifest check) would otherwise be
            // hammered every watch-interval tick. `deferredAttempt` reads the
            // count from *before* this deferral, so the first one always backs
            // off 60 s regardless of how the caller sequences retries.
            let attempt = state.deferredAttempt(base)
            let backoff = min(1800.0, 60.0 * pow(2.0, Double(attempt)))
            state.clearProcessing(base)
            state.markDeferred(base, retryAfter: backoff)
            return ProcessResult(status: .deferred, base: base, message: retry.message)
        } catch is CancellationError {
            // A pause or quit is not a verdict on the file: leave it pending, never `.failed`.
            state.clearProcessing(base)
            return ProcessResult(status: .skipped, base: base, message: "cancelled; will be picked up again")
        } catch {
            let message = cleanMessage(error)
            state.markFailed(base, message)
            let np = FileManager.default.fileExists(atPath: notePath.path) ? notePath : nil
            return ProcessResult(status: .failed, base: base, message: message, notePath: np)
        }
    }

    /// Record `base` as too short and report it. Not a failure: `.tooshort` is
    /// its own marker so the menu can offer "delete it?" instead of "retry".
    private static func setAsideTooShort(
        state: DistavoState.Store, base: String, source: URL, seconds: Double, minimum: Double
    ) -> ProcessResult {
        let reason = "\(Int(seconds.rounded())) s of audio, below the \(Int(minimum)) s minimum"
        state.markTooShort(base, reason, fileSize: DistavoState.fileSize(source))
        return ProcessResult(status: .tooShort, base: base, message: reason)
    }

    /// Replace a bulky WAV recording with the 16 kHz mono 16-bit WAV the
    /// transcriber consumed (Vikunja #2061) — the recorder's 48 kHz stereo
    /// float32 take is ~20x larger and, once the note is written, only ever
    /// re-read for a retry, which the compact copy serves equally well.
    /// Only `.wav` sources are touched, and only when the compact copy is
    /// under half the size, so a phone's M4A or an already-small WAV is left
    /// alone. Atomic (`replaceItemAt`), so a crash mid-copy leaves the
    /// original. Returns a "486 MB → 24 MB" label, or nil when nothing
    /// happened (including on any error — never fail a written note over
    /// housekeeping).
    static func compactRecording(source: URL, compactWav: URL) -> String? {
        guard source.pathExtension.lowercased() == "wav" else { return nil }
        let fm = FileManager.default
        guard let sourceSize = (try? fm.attributesOfItem(atPath: source.path))?[.size] as? Int,
              let compactSize = (try? fm.attributesOfItem(atPath: compactWav.path))?[.size] as? Int,
              compactSize > 0, compactSize * 2 < sourceSize else { return nil }
        // Stage a copy beside the recording so the replace stays on one volume.
        let staged = source.deletingLastPathComponent()
            .appendingPathComponent(".\(source.lastPathComponent).compact-\(UUID().uuidString)")
        do {
            try fm.copyItem(at: compactWav, to: staged)
            _ = try fm.replaceItemAt(source, withItemAt: staged)
        } catch {
            try? fm.removeItem(at: staged)
            return nil
        }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return "\(formatter.string(fromByteCount: Int64(sourceSize))) → \(formatter.string(fromByteCount: Int64(compactSize)))"
    }

    /// Built per call (cheap) so the zone is the one in force NOW, not whatever
    /// `.current` was the first time any code parsed a name; the time zone is
    /// injectable for the same reason.
    private static func recorderNameFormatter(_ timeZone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f
    }

    /// When the recording started: the built-in recorder's file name
    /// ("Meeting 2026-09-16 16.13.08.wav", local time) is authoritative and
    /// survives copies and syncs; otherwise the file's creation date, which
    /// a phone recording or a dropped export usually keeps; nil if neither.
    static func meetingDate(for url: URL, timeZone: TimeZone = .current) -> Date? {
        let stem = url.deletingPathExtension().lastPathComponent
        if let date = recorderNameDate(stem, timeZone: timeZone) { return date }
        // Phone / export names (`interview-22-10-2026-10.00`) beat the copy-time file date (#4018).
        if let date = RecordingStamp.parse(stem, timeZone: timeZone) { return date }
        return (try? FileManager.default.attributesOfItem(atPath: url.path))?[.creationDate] as? Date
    }

    /// Start of the recording for NOTE dating (#4018), in order of evidence: the recorder's or a phone's
    /// name stamp, the container `creation_time` minus the duration, the file system date. Async convenience over
    /// the pure `noteStart(for:created:duration:)`; `processOne` does the two awaits itself (see there).
    static func noteStart(for url: URL, deps: PipelineDeps, timeZone: TimeZone = .current) async -> Date? {
        if let named = noteStartFromName(url, timeZone: timeZone) { return named }
        let created = await deps.containerCreationDate(url)
        let duration = created == nil ? nil : await deps.audioDurationSeconds(url)
        return noteStart(for: url, created: created, duration: duration, timeZone: timeZone)
    }

    /// The name-stamp step of `noteStart` alone (recorder name, then a phone's stamp).
    static func noteStartFromName(_ url: URL, timeZone: TimeZone = .current) -> Date? {
        let stem = url.deletingPathExtension().lastPathComponent
        return recorderNameDate(stem, timeZone: timeZone) ?? RecordingStamp.parse(stem, timeZone: timeZone)
    }

    /// `noteStart` once the container date and the duration are known (pure). No await inside: an async
    /// `noteStart` awaiting a real async dependency aborted the test process on the macOS 26 runtime with
    /// Xcode 26.4-26.6 ("freed pointer was not the last allocation" at its first await, CI 2026-11-14).
    static func noteStart(for url: URL, created: Date?, duration: Double?, timeZone: TimeZone = .current) -> Date? {
        if let named = noteStartFromName(url, timeZone: timeZone) { return named }
        if let created, let duration, let start = RecordingStamp.start(creation: created, duration: duration) {
            return start
        }
        return meetingDate(for: url, timeZone: timeZone)
    }

    /// The media's embedded creation date (AVAsset), nil when absent.
    public static func containerCreation(_ url: URL) async -> Date? {
        await creationDateMetadata(url)
    }

    /// The asset's `creationDate` metadata, nil when absent or unreadable.
    ///
    /// Synchronous on purpose: awaiting AVFoundation's `asset.load(.creationDate)` aborted the process on the
    /// macOS 26 runtime with Xcode 26.4-26.6 ("freed pointer was not the last allocation" at the await that called
    /// it, bisected and backtraced on CI 2026-11-14), which would crash a release built there whenever a dropped
    /// file without a name stamp is dated. The deprecated synchronous properties read the same metadata.
    static func creationDateMetadata(_ url: URL) async -> Date? {
        // Off the Swift task entirely: AVFoundation runs on a plain GCD thread with no current task.
        await withCheckedContinuation { (cont: CheckedContinuation<Date?, Never>) in
            DispatchQueue.global(qos: .utility).async { cont.resume(returning: creationDateMetadataSync(url)) }
        }
    }

    public static func creationDateMetadataSync(_ url: URL) -> Date? {
        let asset = AVURLAsset(url: url)
        return asset.creationDate?.dateValue
    }

    /// The start time in a recorder-style name, exactly as before #2946 (any
    /// position, with or without the "Meeting " prefix). A calendar-renamed file is
    /// covered by its sidecar's `recordingStart`, which callers prefer.
    static func recorderNameDate(_ stem: String, timeZone: TimeZone = .current) -> Date? {
        guard let range = stem.range(of: #"\d{4}-\d{2}-\d{2} \d{2}\.\d{2}\.\d{2}"#, options: .regularExpression)
        else { return nil }
        return recorderNameFormatter(timeZone).date(from: String(stem[range]))
    }

    /// The built-in recorder's own file name, exactly (`MeetingRecorder.fileName`:
    /// "Meeting yyyy-MM-dd HH.mm.ss.wav"), anchored at both ends. Unlike
    /// `recorderNameDate` (the permissive PROMPT rule, unchanged from before
    /// #2946) this is the only name accepted as calendar-lookup evidence: other
    /// names, a calendar-folded title or an imported file's name, are
    /// attacker-influenceable.
    static func exactRecorderNameDate(_ url: URL, timeZone: TimeZone = .current) -> Date? {
        guard url.pathExtension.lowercased() == "wav" else { return nil }
        let stem = url.deletingPathExtension().lastPathComponent
        guard stem.range(of: #"^Meeting \d{4}-\d{2}-\d{2} \d{2}\.\d{2}\.\d{2}$"#, options: .regularExpression) != nil
        else { return nil }
        return recorderNameDate(stem, timeZone: timeZone)
    }

    /// Recording start evidence for the calendar lookup of a file WITHOUT a
    /// calendar sidecar: the recorder's exact file name, else the media's embedded
    /// creation date (AVAsset common metadata). nil when neither exists -
    /// filesystem dates and any other file name are NOT evidence.
    public static func recordingStartEvidence(_ url: URL) async -> Date? {
        if let d = exactRecorderNameDate(url) { return d }
        return await creationDateMetadata(url)
    }

    /// `recordingStartEvidence` without an await, for the `PipelineDeps` default (see `creationDateMetadata`).
    public static func recordingStartEvidenceSync(_ url: URL) -> Date? {
        exactRecorderNameDate(url) ?? creationDateMetadataSync(url)
    }

    /// The router's detections from the transcribe result, formatted for the
    /// menu — nil when absent (server path) or empty.
    static func detectedLanguages(from transcribeResult: [String: Any]) -> String? {
        let detections: [(code: String, probability: Double)] =
            (transcribeResult["detections"] as? [[String: Any]] ?? []).compactMap { entry in
                guard let code = entry["code"] as? String else { return nil }
                return (code: code, probability: entry["probability"] as? Double ?? 0)
            }
        return NoteProvenance.detectedLanguages(detections)
    }

    /// The single highest-probability detected language code (e.g. "ca"),
    /// or nil when the transcribe result carries no detections (the server
    /// path, or the built-in engine outside Automatic mode). Feeds
    /// `NoteContext.noteLanguage` when the note language resolves to "auto".
    static func dominantLanguageCode(from transcribeResult: [String: Any]) -> String? {
        let detections: [(code: String, probability: Double)] =
            (transcribeResult["detections"] as? [[String: Any]] ?? []).compactMap { entry in
                guard let code = entry["code"] as? String else { return nil }
                return (code: code, probability: entry["probability"] as? Double ?? 0)
            }
        return detections.max(by: { $0.probability < $1.probability })?.code
    }

    /// Builds the note's provenance footer from the transcribe result's

    /// optional `"engine"` / `"detections"` keys (set only by the app layer's
    /// embedded path — `PipelineDeps.live()`'s own transcribe closure never
    /// sets them, and neither does the WhisperX server response). Empty
    /// (no footer appended) when `"engine"` is absent.
    static func provenanceFooter(from transcribeResult: [String: Any]) -> String {
        guard let engine = transcribeResult["engine"] as? String else { return "" }
        let detections: [(code: String, probability: Double)] =
            (transcribeResult["detections"] as? [[String: Any]] ?? []).compactMap { entry in
                guard let code = entry["code"] as? String else { return nil }
                return (code: code, probability: entry["probability"] as? Double ?? 0)
            }
        return NoteProvenance.footer(
            engine: engine, detections: detections,
            languageUsed: transcribeResult["language_used"] as? String,
            recommendation: transcribeResult["recommendation"] as? String,
            notes: transcribeResult["footer_notes"] as? [String] ?? [])
    }

    /// Writes a rejected summary into the work dir. Returns nil on success, else why it failed, so the
    /// caller's message never claims a file that is not there (#4374, docs/error-handling-audit.md).
    static func quarantine(_ text: String, at url: URL, workDir: URL) -> String? {
        do {
            try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Options for the one retry after a repetition collapse (#4011): firmer penalty over a longer window,
    /// a little more temperature and a different seed, so the retry does not walk the same loop.
    static func stiffened(_ o: SummariseOptions) -> SummariseOptions {
        var n = o
        n.repeatPenalty = max(o.repeatPenalty, 1.0) + 0.2
        n.repeatLastN = max(o.repeatLastN, 1024)
        n.temperature = max(o.temperature, 0.3)
        n.seed = o.seed &+ 1
        return n
    }

    /// Roughly ten minutes of speech per part (~9,000 characters). Fewer than two parts means the whole
    /// transcript is already short and chunking cannot help.
    static let collapsePartTokens = 3000
    static func collapseParts(of transcript: String) -> [String] {
        EmbeddedSummaryPlanner.chunks(transcript: transcript, budgetTokens: collapsePartTokens)
    }

    /// Largest transcript share of one part when a long transcript is summarised in parts (#6759): about an
    /// hour of talk, short enough for an 8B model to keep track of, long enough that few parts are needed.
    static let longPartMaxTokens = 16_000

    /// The parts of a transcript too long for the Ollama context window (`num_ctx`), or nil when it fits (or
    /// the target is on-device, which chunks for itself). Fits = the estimated prompt plus the reply budget
    /// (`num_predict`) is within `num_ctx`; each part leaves the same room for the instructions and the reply.
    static func longTranscriptParts(_ transcript: String, target: SummariseTarget,
                                    options: SummariseOptions, context: NoteContext) -> [String]? {
        guard case .ollama = target, options.numCtx > 0 else { return nil }
        let instructions = EmbeddedSummaryTokens.estimate(context.prompt(transcript: ""))
        let whole = instructions + EmbeddedSummaryTokens.estimate(transcript)
        guard whole + max(0, options.numPredict) > options.numCtx else { return nil }
        let room = options.numCtx - max(0, options.numPredict) - instructions - 256   // 256: chunk-join slack
        let budget = min(longPartMaxTokens, max(1_000, room))
        let parts = EmbeddedSummaryPlanner.chunks(transcript: transcript, budgetTokens: budget)
        return parts.count >= 2 ? parts : nil
    }

    /// Part notes for `parts`, merged into one input for the final pass; nil when no part produced a usable note.
    /// A part that fails or is rejected is left out (logged); a retryable error or a cancel stops all.
    static func summariseInParts(
        _ parts: [String], target: SummariseTarget, options: SummariseOptions, context: NoteContext,
        summarise: (String, SummariseTarget, SummariseOptions, NoteContext) async throws -> String
    ) async throws -> String? {
        var partNotes: [String] = []
        for (i, part) in parts.enumerated() {
            try Task.checkCancellation()
            do {
                let raw = try await summarise(part, target, options, context)
                let note = SummaryCleaner.stripLeakedWorkingSteps(raw) { print("[Distavo] \($0)") }
                if SummaryValidator.validate(note).isEmpty { partNotes.append(note) }
                else { print("[Distavo] part \(i + 1)/\(parts.count) rejected; left out of the merge") }
            } catch is CancellationError { throw CancellationError()
            } catch let retry as RetryableDependencyError { throw retry
            } catch { print("[Distavo] part \(i + 1)/\(parts.count) failed (\(error.localizedDescription)); left out of the merge") }
        }
        return partNotes.isEmpty ? nil : EmbeddedSummaryPrompt.merge(partials: partNotes)
    }

    /// For a transcript too long for the Ollama context (#6759): the merged part notes to summarise instead,
    /// and how many parts the transcript was cut into; nil when it fits (or no part note came back, in which
    /// case the caller sends the transcript as before). Merged notes that still overflow are merged in parts
    /// again, at most twice. Shared by `processOne` and `regenerate`.
    static func longTranscriptInput(
        _ transcript: String, target: SummariseTarget, options: SummariseOptions, context: NoteContext,
        summarise: (String, SummariseTarget, SummariseOptions, NoteContext) async throws -> String
    ) async throws -> (input: String, parts: Int)? {
        guard let parts = longTranscriptParts(transcript, target: target, options: options, context: context) else {
            return nil
        }
        print("[Distavo] long transcript (\(EmbeddedSummaryTokens.estimate(transcript)) tokens est.): summarising in \(parts.count) parts")
        guard var merged = try await summariseInParts(parts, target: target, options: options, context: context,
                                                     summarise: summarise) else { return nil }
        for _ in 0..<2 {
            guard let again = longTranscriptParts(merged, target: target, options: options, context: context),
                  let remerged = try await summariseInParts(again, target: target, options: options, context: context,
                                                            summarise: summarise) else { break }
            merged = remerged
        }
        return (merged, parts.count)
    }

    /// Footer line of a note summarised in parts (#6759).
    static func partedSummaryNote(parts: Int) -> String {
        "The transcript was too long for the summary model in one go, so it was summarised in \(parts) parts and the part notes merged."
    }

    /// Body of the fallback note written when the summary collapsed twice (#4011).
    static func transcriptOnlyNote(reason: String, transcript: String) -> String {
        "# Meeting notes\n\n"
        + "> No summary: the model's output looped twice and was rejected (\(reason)). "
        + "Use Regenerate Note… with another model; the transcript is below.\n\n"
        + "## Transcript\n\n" + transcript.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    /// Only "summary is empty" and "summary is truncated" failures (Vikunja
    /// #2203) are worth retrying the summarise call once. If overlong or
    /// repetition-collapse also fired (a structurally different, unlikely-
    /// to-self-heal problem), that failure kind wins and there is no retry —
    /// unchanged from before this change.
    static func isRetryableTruncation(_ failures: [String]) -> Bool {
        guard !failures.isEmpty else { return false }
        let hasNonRetryable = failures.contains {
            $0.contains("repetition collapse") || $0.contains("unusually long")
        }
        guard !hasNonRetryable else { return false }
        return failures.contains { $0.hasPrefix("summary is empty") || $0.hasPrefix("summary is truncated") }
    }

    /// A transcript-only note still carries what the owner captured live: typed Quick Notes (as Highlights) and
    /// Key moments markers. Neither depends on the model, so neither may vanish with the summary.
    static func keepingLiveCapture(_ body: String, scratchpad: ScratchpadNotes?, keyMoments: String) -> String {
        var out = body
        if let pad = scratchpad { out = pad.ensureHighlights(in: out) }
        return RecordingBookmarks.appending(keyMoments, to: out)
    }

    /// True for a conversion failure that says nothing about the file itself (cancelled, offline volume, busy file,
    /// disk full, permission): it stays retryable. Machine-level ones (`isMachineLevelConvertFailure`) never count;
    /// the rest are capped at `Store.transientFailureCap` in a row (#5283).
    static func isTransientConvertFailure(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let ns = error as NSError
        let transient: Bool
        switch ns.domain {
        case NSURLErrorDomain:
            transient = [NSURLErrorCancelled, NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost,
                         NSURLErrorNotConnectedToInternet, NSURLErrorCannotConnectToHost].contains(ns.code)
        case NSCocoaErrorDomain:
            transient = [NSFileWriteOutOfSpaceError, NSFileWriteNoPermissionError, NSFileReadNoPermissionError,
                         NSFileLockingError, NSUserCancelledError].contains(ns.code)
        case NSPOSIXErrorDomain:
            // EIO and EPERM are deliberately absent: a bad sector or a permanent refusal is the file's problem.
            transient = [ENOSPC, EACCES, EBUSY, EINTR, EAGAIN, EDQUOT].contains(Int32(ns.code))
        case NSOSStatusErrorDomain:
            transient = ns.code == -34   // dskFulErr
        default:
            transient = false
        }
        if transient { return true }
        // AVFoundation / AudioToolbox wrap the real cause one level down.
        if let under = ns.userInfo[NSUnderlyingErrorKey] as? Error { return isTransientConvertFailure(under) }
        return false
    }

    /// True when the machine, not the recording, is at fault (disk full, quota, permission): such a failure is
    /// retried at every launch and never counted toward `.unreadable` (the cap is for offline volumes and the like).
    static func isMachineLevelConvertFailure(_ error: Error) -> Bool {
        let ns = error as NSError
        switch ns.domain {
        case NSCocoaErrorDomain:
            if [NSFileWriteOutOfSpaceError, NSFileWriteNoPermissionError, NSFileReadNoPermissionError].contains(ns.code) { return true }
        case NSPOSIXErrorDomain:
            if [ENOSPC, EACCES, EDQUOT].contains(Int32(ns.code)) { return true }
        case NSOSStatusErrorDomain:
            if ns.code == -34 { return true }
        default: break
        }
        if let under = ns.userInfo[NSUnderlyingErrorKey] as? Error { return isMachineLevelConvertFailure(under) }
        return false
    }

    /// Prefer a typed error's human message over the default struct description.
    static func cleanMessage(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }

    /// True when `wavPath` already exists and was written at or after
    /// `sourcePath`'s modification date — i.e. it is a previous, complete
    /// conversion of this exact recording, not a stale leftover from an older
    /// file that happened to share a base name.
    static func wavIsFresh(wavPath: URL, sourcePath: URL) -> Bool {
        let fm = FileManager.default
        guard let wavDate = (try? fm.attributesOfItem(atPath: wavPath.path))?[.modificationDate] as? Date,
              let sourceDate = (try? fm.attributesOfItem(atPath: sourcePath.path))?[.modificationDate] as? Date
        else { return false }
        return wavDate >= sourceDate
    }
}

/// Process all pending recordings once (mirrors `WatcherController.scan_once`).
public enum Scanner {
    public static func scanOnce(
        config: Config, deps: PipelineDeps,
        stableChecks: Int = 3, stableDelay: Double = 2.0
    ) async -> [ProcessResult] {
        let recordingsDir = Config.resolvePath(config.recordingsDir)
        let workDir = Config.resolvePath(config.workDir)
        let notesDir = Config.resolvePath(config.notesDir)
        guard let state = try? DistavoState.Store(
            stateDir: workDir.appendingPathComponent(".state"), notesDir: notesDir) else { return [] }
        let pending = DistavoState.iterPending(recordingsDir: recordingsDir, state: state)
        var results: [ProcessResult] = []
        for path in pending {
            results.append(await Pipeline.processOne(
                path: path, config: config, deps: deps,
                stableChecks: stableChecks, stableDelay: stableDelay))
        }
        return results
    }
}
