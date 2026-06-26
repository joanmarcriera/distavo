import Foundation

public enum ProcessStatus: String, Equatable {
    case done
    case skipped
    case deferredNeedLocal = "deferred_need_local"
    case failed
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
public struct PipelineDeps {
    public var convertToWav: (URL, URL) async throws -> Void
    public var transcribe: (URL, TranscribeConfig) async throws -> [String: Any]
    public var ollamaReachable: (String) async -> Bool
    public var summarise: (_ transcript: String, _ url: String, _ model: String,
                           _ options: SummariseOptions, _ noteOwner: String,
                           _ userSpeaker: String) async throws -> String

    public init(
        convertToWav: @escaping (URL, URL) async throws -> Void,
        transcribe: @escaping (URL, TranscribeConfig) async throws -> [String: Any],
        ollamaReachable: @escaping (String) async -> Bool,
        summarise: @escaping (String, String, String, SummariseOptions, String, String) async throws -> String
    ) {
        self.convertToWav = convertToWav
        self.transcribe = transcribe
        self.ollamaReachable = ollamaReachable
        self.summarise = summarise
    }

    /// Real dependencies wired to AVFoundation + the HTTP clients.
    public static func live() -> PipelineDeps {
        let whisper = WhisperXClient()
        let ollama = OllamaClient()
        return PipelineDeps(
            convertToWav: { try await AudioConverter.convertToWav(source: $0, dest: $1) },
            transcribe: { try await whisper.transcribe(wavURL: $0, config: $1) },
            ollamaReachable: { await ollama.reachable($0) },
            summarise: { transcript, url, model, options, owner, speaker in
                let prompt = Prompt.build(transcript: transcript, noteOwner: owner, userSpeaker: speaker)
                return try await ollama.generate(url: url, model: model, prompt: prompt, options: options)
            })
    }
}

/// Port of `meeting_pipeline/pipeline.py`.
public enum Pipeline {

    /// Choose the Ollama target (server vs local) or signal deferral.
    static func chooseOllama(
        _ config: Config, reachable: (String) async -> Bool
    ) async -> (url: String, model: String)? {
        let s = config.summarise
        if s.backend == "local" { return (s.local.url, s.local.model) }
        if await reachable(s.server.url) { return (s.server.url, s.server.model) }
        if s.allowLocalFallback { return (s.local.url, s.local.model) }
        return nil
    }

    public static func processOne(
        path: URL, config: Config, deps: PipelineDeps,
        stableChecks: Int = 3, stableDelay: Double = 2.0
    ) async -> ProcessResult {
        let recordingsDir = Config.resolvePath(config.recordingsDir)
        let base = SeshatState.baseFor(recordingsDir: recordingsDir, path: path)
        let notesDir = Config.resolvePath(config.notesDir)
        let workDir = Config.resolvePath(config.workDir)

        let state: SeshatState.Store
        do {
            state = try SeshatState.Store(
                stateDir: workDir.appendingPathComponent(".state"), notesDir: notesDir)
        } catch {
            return ProcessResult(status: .failed, base: base,
                                 message: "state init failed: \(error.localizedDescription)")
        }

        if state.isDone(base) {
            return ProcessResult(status: .skipped, base: base,
                                 message: "already processed", notePath: state.notePath(base))
        }
        if !SeshatState.waitUntilStable(path, checks: stableChecks, delay: stableDelay) {
            return ProcessResult(status: .skipped, base: base, message: "file still changing")
        }
        if state.isProcessing(base) {
            return ProcessResult(status: .skipped, base: base, message: "already being processed")
        }

        guard let target = await chooseOllama(config, reachable: deps.ollamaReachable) else {
            return ProcessResult(status: .deferredNeedLocal, base: base,
                                 message: "Server Ollama offline; local fallback not allowed yet")
        }

        state.markProcessing(base)
        try? FileManager.default.createDirectory(at: notesDir, withIntermediateDirectories: true)
        let notePath = state.notePath(base)

        do {
            let wavPath = workDir.appendingPathComponent("\(base).wav")
            try await deps.convertToWav(path, wavPath)

            let result = try await deps.transcribe(wavPath, config.transcribe)
            let clean = TranscriptCleaner.clean(TranscriptCleaner.segments(from: result))
            if clean.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                state.markFailed(base, "empty transcript")
                return ProcessResult(status: .failed, base: base, message: "empty transcript")
            }
            let transcriptPath = workDir.appendingPathComponent("\(base).transcript.clean.txt")
            try? (clean + "\n").write(to: transcriptPath, atomically: true, encoding: .utf8)

            let summary = try await deps.summarise(
                clean, target.url, target.model, config.summarise.options,
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
        guard let state = try? SeshatState.Store(
            stateDir: workDir.appendingPathComponent(".state"), notesDir: notesDir) else { return [] }
        let pending = SeshatState.iterPending(recordingsDir: recordingsDir, state: state)
        var results: [ProcessResult] = []
        for path in pending {
            results.append(await Pipeline.processOne(
                path: path, config: config, deps: deps,
                stableChecks: stableChecks, stableDelay: stableDelay))
        }
        return results
    }
}
