import Foundation

public enum ProcessStatus: String, Equatable {
    case done
    case skipped
    case deferredNeedLocal = "deferred_need_local"
    case failed
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
    /// Apple Foundation Models on this Mac — no network, no endpoint.
    case embedded
}

public struct ProcessResult: Equatable {
    public let status: ProcessStatus
    public let base: String
    public let message: String
    public var notePath: URL?
    public var transcriptPath: URL?

    public init(status: ProcessStatus, base: String, message: String,
                notePath: URL? = nil, transcriptPath: URL? = nil) {
        self.status = status; self.base = base; self.message = message
        self.notePath = notePath; self.transcriptPath = transcriptPath
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

public struct PipelineDeps {
    public var convertToWav: (URL, URL) async throws -> Void
    public var transcribe: (URL, TranscribeConfig) async throws -> [String: Any]
    public var ollamaReachable: (String) async -> Bool
    /// Readiness of the on-device summariser. DistavoCore is dependency-free and
    /// cannot import DistavoEmbedded, so this comes in through the DI seam like
    /// `ollamaReachable`. Defaults to `.ready`, keeping every existing caller and
    /// test unchanged; the app layer wires it to `EmbeddedSummariser`.
    public var embeddedReadiness: () async -> EmbeddedReadiness
    public var summarise: (_ transcript: String, _ target: SummariseTarget,
                           _ options: SummariseOptions, _ noteOwner: String,
                           _ userSpeaker: String) async throws -> String
    /// Optional stage-boundary progress. Defaults to nil so tests and callers
    /// that don't care are unaffected (preserves the DI seam).
    public var onPhase: (@Sendable (ProcessingPhase) -> Void)?

    public init(
        convertToWav: @escaping (URL, URL) async throws -> Void,
        transcribe: @escaping (URL, TranscribeConfig) async throws -> [String: Any],
        ollamaReachable: @escaping (String) async -> Bool,
        summarise: @escaping (String, SummariseTarget, SummariseOptions, String, String) async throws -> String,
        onPhase: (@Sendable (ProcessingPhase) -> Void)? = nil,
        embeddedReadiness: @escaping () async -> EmbeddedReadiness = { .ready }
    ) {
        self.convertToWav = convertToWav
        self.transcribe = transcribe
        self.ollamaReachable = ollamaReachable
        self.summarise = summarise
        self.onPhase = onPhase
        self.embeddedReadiness = embeddedReadiness
    }

    /// Real dependencies wired to AVFoundation + the HTTP clients.
    public static func live() -> PipelineDeps {
        let whisper = WhisperXClient()
        let ollama = OllamaClient()
        return PipelineDeps(
            convertToWav: { try await AudioConverter.convertToWav(source: $0, dest: $1) },
            transcribe: { try await whisper.transcribe(wavURL: $0, config: $1) },
            ollamaReachable: { await ollama.reachable($0) },
            summarise: { transcript, target, options, owner, speaker in
                // DistavoCore is dependency-free, so it can only serve the Ollama
                // target. The app layer (AppPipelineDeps) wraps this to route
                // `.embedded` at the FoundationModels engine.
                guard case let .ollama(url, model) = target else {
                    throw OllamaError("On-device summarisation is not available in this build.")
                }
                let prompt = Prompt.build(transcript: transcript, noteOwner: owner, userSpeaker: speaker)
                return try await ollama.generate(url: url, model: model, prompt: prompt, options: options)
            })
    }
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
        embeddedReadiness: () async -> EmbeddedReadiness = { .ready }
    ) async -> SummariserChoice {
        let s = config.summarise
        if s.backend == "embedded" && s.embeddedEnabled {
            switch await embeddedReadiness() {
            case .ready: return .use(.embedded)
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
        stableChecks: Int = 3, stableDelay: Double = 2.0
    ) async -> ProcessResult {
        let recordingsDir = Config.resolvePath(config.recordingsDir)
        let base = DistavoState.baseFor(recordingsDir: recordingsDir, path: path)
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

        let target: SummariseTarget
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

        state.markProcessing(base)
        try? FileManager.default.createDirectory(at: notesDir, withIntermediateDirectories: true)
        let notePath = state.notePath(base)

        do {
            let wavPath = workDir.appendingPathComponent("\(base).wav")
            deps.onPhase?(.converting)
            try await deps.convertToWav(path, wavPath)

            deps.onPhase?(.transcribing)
            let result = try await deps.transcribe(wavPath, config.transcribe)
            let clean = TranscriptCleaner.clean(TranscriptCleaner.segments(from: result))
            if clean.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                state.markFailed(base, "empty transcript")
                return ProcessResult(status: .failed, base: base, message: "empty transcript")
            }
            let transcriptPath = workDir.appendingPathComponent("\(base).transcript.clean.txt")
            try? (clean + "\n").write(to: transcriptPath, atomically: true, encoding: .utf8)

            deps.onPhase?(.summarising)
            let summary = try await deps.summarise(
                clean, target, config.summarise.options,
                config.noteOwner, config.userSpeaker)
            try summary.write(to: notePath, atomically: true, encoding: .utf8)

            let failures = SummaryValidator.validate(summary)
            if !failures.isEmpty {
                let message = failures.joined(separator: "; ")
                state.markFailed(base, message)
                return ProcessResult(status: .failed, base: base, message: message,
                                     notePath: notePath, transcriptPath: transcriptPath)
            }
            state.markDone(base)
            return ProcessResult(status: .done, base: base, message: "note written",
                                 notePath: notePath, transcriptPath: transcriptPath)
        } catch {
            let message = cleanMessage(error)
            state.markFailed(base, message)
            let np = FileManager.default.fileExists(atPath: notePath.path) ? notePath : nil
            return ProcessResult(status: .failed, base: base, message: message, notePath: np)
        }
    }

    /// Prefer a typed error's human message over the default struct description.
    static func cleanMessage(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
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
