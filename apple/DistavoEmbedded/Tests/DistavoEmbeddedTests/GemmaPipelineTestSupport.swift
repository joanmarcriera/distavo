import XCTest
import AVFoundation
import DistavoCore
@testable import DistavoEmbedded

/// Shared rig for the Gemma pipeline tests (Vikunja #2198): an isolated temp
/// tree (recordings / notes / work / models), a `SummaryModelManager` pointed at
/// that models folder with an injected fetch and in-memory opt-in, and a
/// `PipelineDeps` whose summarise route is the real `GemmaPipelineRoute`.
///
/// Isolation: nothing here reads or writes `~/Library/Application Support/
/// Distavo` (config, work, models) or the user's notes folder; the manager never
/// touches `UserDefaults`; the only global state is `ModelCoordinator.shared`'s
/// progress handler (restored in `capturingLog`) and the failure tracker, which
/// `Rig.init` resets for the model.
final class GemmaRig: @unchecked Sendable {
    static let modelID = "gemma-4-e4b"
    static var model: EmbeddedSummaryModel { EmbeddedSummaryModelCatalog.model(id: modelID) }

    let root: URL
    var models: URL { root.appendingPathComponent("models") }
    var recordings: URL { root.appendingPathComponent("recordings") }
    var work: URL { root.appendingPathComponent("work") }
    var notes: URL { root.appendingPathComponent("notes") }
    let manager: SummaryModelManager
    let fetches = Counter()
    let transcribes = Counter()
    let ollamaChecks = Counter()
    private let lock = NSLock()
    private var segments: [[String: Any]] = []
    private var language: String?

    /// `weights`: a local folder of the model files to "download" (copied, so
    /// the manifest/sha verification runs for real); nil serves empty files,
    /// which the published tokenizer sha rejects.
    init(weights: URL?, optedIn: Bool) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("distavo-gemma-\(UUID().uuidString)", isDirectory: true)
        self.root = root
        for name in ["", "recordings", "work", "notes"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let fetches = self.fetches
        let fetch: SummaryFileFetch = { url, dest, onBytes in
            fetches.add()
            if let weights {
                try FileManager.default.copyItem(at: weights.appendingPathComponent(url.lastPathComponent), to: dest)
            } else {
                try Data().write(to: dest)
            }
            onBytes(1)
        }
        manager = SummaryModelManager(
            root: root.appendingPathComponent("models"), coordinator: ModelCoordinator(), fetch: fetch,
            optIn: .inMemory(initially: optedIn ? [Self.modelID] : []),
            memoryGB: 16, isAppleSilicon: true)
        LocalSummaryFailureTracker.shared.noteSuccess(model: Self.modelID)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func setTranscript(segments: [[String: Any]], language: String?) {
        lock.withLock { self.segments = segments; self.language = language }
    }

    var config: Config {
        var cfg = Config()
        cfg.recordingsDir = recordings.path; cfg.notesDir = notes.path; cfg.workDir = work.path
        cfg.noteOwner = "Marc"; cfg.userSpeaker = "SPEAKER_00"
        cfg.compactRecordingsAfterNote = false
        cfg.summarise.backend = "embedded"; cfg.summarise.embeddedEnabled = true
        cfg.summarise.embeddedModel = Self.modelID
        cfg.summarise.promptStyle = .factsFirst
        cfg.summarise.noteLanguage = "auto"
        return cfg
    }

    /// Same wiring as `PipelineDeps.appLive()` for the embedded-Gemma target
    /// (readiness through the manager, summarise through `GemmaPipelineRoute`),
    /// except: transcription is the canned transcript, and the app target's
    /// edition gate (`SummaryModelEdition`) is not part of this rig.
    func deps(realConvert: Bool = false) -> PipelineDeps {
        PipelineDeps(
            convertToWav: { source, dest in
                if realConvert { try await AudioConverter.convertToWav(source: source, dest: dest) }
                else { try Data([0]).write(to: dest) }
            },
            transcribe: { [self] _, _ in
                transcribes.add()
                let (segs, lang) = lock.withLock { (segments, language) }
                var result: [String: Any] = ["segments": segs]
                if let lang { result["detections"] = [["code": lang, "probability": 0.97]] }
                return result
            },
            ollamaReachable: { [self] _ in ollamaChecks.add(); return false },
            summarise: { [self] transcript, target, _, context in
                guard case .embedded(let id) = target else {
                    throw LocalSummaryError("test rig: pipeline routed to Ollama instead of the local model")
                }
                return try await GemmaPipelineRoute.summarise(
                    transcript: transcript, modelID: id, context: context, root: models, manager: manager)
            },
            embeddedReadiness: { [self] id in await manager.readiness(modelID: id) },
            audioDurationSeconds: { _ in 60 })
    }

    /// Adds an (empty or real) recording and returns its URL.
    func addRecording(named name: String, copying source: URL? = nil) throws -> URL {
        let url = recordings.appendingPathComponent(name)
        if let source { try FileManager.default.copyItem(at: source, to: url) } else { try Data([0, 1, 2, 3]).write(to: url) }
        return url
    }

    func process(_ url: URL) async -> ProcessResult {
        await Pipeline.processOne(path: url, config: config, deps: deps(realConvert: false), stableChecks: 1, stableDelay: 0)
    }

    func state() throws -> DistavoState.Store {
        try DistavoState.Store(stateDir: work.appendingPathComponent(".state"), notesDir: notes)
    }

    /// Poll until the manager's download is no longer running (or time out).
    func waitForDownloadToSettle(timeout: TimeInterval = 120) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if case .downloading = await manager.status(Self.model) { try await Task.sleep(nanoseconds: 200_000_000); continue }
            // `status` can read .notDownloaded for the instant before the task
            // registers; the manager's own state is authoritative.
            if case .inProgress = await manager.downloadState(Self.model) { try await Task.sleep(nanoseconds: 200_000_000); continue }
            return
        }
        XCTFail("download did not settle in \(timeout) s")
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    func add() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}

/// Collects the activity-log lines the pipeline reports through
/// `ModelCoordinator.shared` while `body` runs, restoring the handler after.
final class LogLines: @unchecked Sendable {
    let lock = NSLock(); var all: [String] = []
    func add(_ s: String) { lock.withLock { all.append(s) } }
}

func capturingLog<T>(_ body: () async throws -> T) async rethrows -> (T, [String]) {
    let lines = LogLines()
    await ModelCoordinator.shared.setProgressHandler { lines.add($0) }
    do {
        let value = try await body()
        await ModelCoordinator.shared.setProgressHandler(nil)
        try? await Task.sleep(nanoseconds: 300_000_000)   // let fire-and-forget reports land
        return (value, lines.lock.withLock { lines.all })
    } catch {
        await ModelCoordinator.shared.setProgressHandler(nil)
        throw error
    }
}

/// `[SPEAKER_xx]\ntext` blocks (the shape of the spike's transcripts) as
/// WhisperX-style segments.
func segments(fromBlocks transcript: String) -> [[String: Any]] {
    var out: [[String: Any]] = []
    for (i, block) in transcript.components(separatedBy: "\n\n").enumerated() {
        let lines = block.split(separator: "\n", maxSplits: 1).map(String.init)
        guard lines.count == 2, lines[0].hasPrefix("[SPEAKER_") else { continue }
        let speaker = String(lines[0].dropFirst().dropLast())
        out.append(["speaker": speaker, "text": lines[1], "start": Double(i), "end": Double(i) + 0.9])
    }
    return out
}
