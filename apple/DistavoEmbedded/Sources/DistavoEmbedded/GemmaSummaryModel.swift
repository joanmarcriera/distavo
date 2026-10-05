import Foundation
import DistavoCore

// Download, verification and readiness of the local Gemma summary model
// (Vikunja #2198, slice S5). Follows the WhisperKit-model patterns:
//   - files live under `EmbeddedModelStore.modelsDirectory/summary/<id>`, so
//     "Remove downloaded models" deletes them with everything else — after
//     `ModelCoordinator.removeAllModels` has cancelled any in-flight download
//     (`SummaryModelManager.cancelAndForgetAll`) and the manager has stopped
//     auto-starting it;
//   - a `manifest.json` (generated from local hashes) is verified with
//     `ModelManifestCheck`, then the `.distavo-verified` sentinel is written;
//   - two consecutive manifest failures are permanent (`ModelCoordinator`'s
//     failure counter), a first one discards the download and retries;
//   - the pure defer-versus-fail decision is `SummaryModelReadiness` in
//     DistavoCore.
// Locking: the 5 GB download deliberately does NOT take
// `ModelCoordinator.withExclusiveAccess` — that would block transcription for
// the whole transfer. It is single-flight per model through the manager's own
// task table instead. Summarising, which reads the weights for about a minute,
// DOES hold the coordinator's exclusive lock (see `GemmaSummariser`), so
// "Remove downloaded models" can never delete files mid-read.
// Downloads come from the revision pinned in the catalogue. The plan is to
// mirror the files under Marc's Hugging Face account later; nothing here
// uploads anywhere.

public enum SummaryModelStore {
    /// `<models>/summary/<id>`.
    public static func directory(for model: EmbeddedSummaryModel,
                                 root: URL = EmbeddedModelStore.modelsDirectory) -> URL {
        root.appendingPathComponent("summary", isDirectory: true)
            .appendingPathComponent(model.id, isDirectory: true)
    }

    /// Where a download is assembled before it is verified and moved into place.
    static func stagingDirectory(for model: EmbeddedSummaryModel, root: URL) -> URL {
        root.appendingPathComponent("summary", isDirectory: true)
            .appendingPathComponent(model.id + ".partial", isDirectory: true)
    }

    /// Cheap check used on every scan: the folder exists and carries the
    /// sentinel written after a successful manifest verification.
    public static func isVerified(_ model: EmbeddedSummaryModel,
                                  root: URL = EmbeddedModelStore.modelsDirectory) -> Bool {
        let dir = directory(for: model, root: root)
        return ModelManifestCheck.hasSentinel(folder: dir)
            && model.files.allSatisfy {
                FileManager.default.fileExists(atPath: dir.appendingPathComponent($0.path).path)
            }
    }
}

/// Fetches `url` into `destination` (a file that does not exist yet), calling
/// `onBytes` with the number of new bytes received.
typealias SummaryFileFetch = @Sendable (_ url: URL, _ destination: URL,
                                        _ onBytes: @escaping @Sendable (Int64) -> Void) async throws -> Void

/// What Settings shows for a downloadable summary model.
public enum SummaryModelStatus: Equatable, Sendable {
    case notDownloaded
    case downloading(fraction: Double)
    case ready
    /// The user removed it; nothing will fetch it again until they ask.
    case removed
    case failed(String)
}

/// Whether the user explicitly chose to download a model (Settings button).
/// A 5 GB transfer must never start from a background scan, so readiness only
/// auto-starts a download for a model whose opt-in is set. Persisted so a
/// download interrupted by a relaunch resumes without asking again.
struct SummaryDownloadOptIn: Sendable {
    var isSet: @Sendable (String) -> Bool
    var set: @Sendable (String, Bool) -> Void

    static let userDefaults = SummaryDownloadOptIn(
        isSet: { UserDefaults.standard.bool(forKey: "summaryModelDownloadOptIn.\($0)") },
        set: { UserDefaults.standard.set($1, forKey: "summaryModelDownloadOptIn.\($0)") })

    /// Isolated in-memory flags (tests; never touches real preferences).
    static func inMemory(initially: Set<String> = []) -> SummaryDownloadOptIn {
        let box = OptInBox(initially)
        return SummaryDownloadOptIn(isSet: { box.get($0) }, set: { box.put($0, $1) })
    }
}

private final class OptInBox: @unchecked Sendable {
    private let lock = NSLock(); private var ids: Set<String>
    init(_ ids: Set<String>) { self.ids = ids }
    func get(_ id: String) -> Bool { lock.withLock { ids.contains(id) } }
    func put(_ id: String, _ on: Bool) { lock.withLock { if on { _ = ids.insert(id) } else { _ = ids.remove(id) } } }
}

/// Owns the summary model's download lifecycle and answers readiness.
public actor SummaryModelManager {
    public static let shared = SummaryModelManager()

    private let root: URL
    private let fetch: SummaryFileFetch
    private let coordinator: ModelCoordinator

    private var tasks: [String: Task<Void, Never>] = [:]
    private var fractions: [String: Double] = [:]
    private var permanentFailures: [String: String] = [:]
    /// Models the user removed: not re-downloaded behind their back by the
    /// next scan; an explicit `startDownload` (Settings) clears the flag.
    private var removedByUser: Set<String> = []
    private var lastError: [String: String] = [:]
    private let optIn: SummaryDownloadOptIn
    /// Physical memory / CPU the readiness decision sees (injectable so tests do
    /// not depend on the machine they run on; CI runners have 7 GB).
    private let memoryGB: Int
    private let isAppleSilicon: Bool

    public init() {
        self.init(root: EmbeddedModelStore.modelsDirectory, coordinator: .shared,
                  fetch: urlSessionFetch, optIn: .userDefaults)
    }

    init(root: URL, coordinator: ModelCoordinator, fetch: @escaping SummaryFileFetch,
         optIn: SummaryDownloadOptIn = .inMemory(initially: ["gemma-4-e4b"]),
         memoryGB: Int = Int(HardwareProbe.physicalMemoryBytes / (1024 * 1024 * 1024)),
         isAppleSilicon: Bool = HardwareProbe.isAppleSilicon) {
        self.memoryGB = memoryGB; self.isAppleSilicon = isAppleSilicon
        self.root = root; self.coordinator = coordinator; self.fetch = fetch; self.optIn = optIn
    }

    /// For Settings: the accurate state of a downloadable model.
    public func status(_ model: EmbeddedSummaryModel) async -> SummaryModelStatus {
        switch await downloadState(model) {
        case .verified: return .ready
        case .inProgress(let f): return .downloading(fraction: f)
        case .failedPermanently(let why): return .failed(why)
        case .notStarted, .manifestMismatch:
            if let why = lastError[model.id] { return .failed(why) }
            return removedByUser.contains(model.id) ? .removed : .notDownloaded
        }
    }

    // MARK: Readiness

    /// Whether `modelID` can summarise right now, starting the download when
    /// it is simply not there yet. Called from `PipelineDeps.embeddedReadiness`
    /// BEFORE transcription: `.temporarilyUnavailable` defers the recording
    /// (never fails it), and the next scan finds the model ready.
    public func readiness(modelID: String) async -> EmbeddedReadiness {
        let model = EmbeddedSummaryModelCatalog.model(id: modelID)
        let state = await downloadState(model)
        let freeMB = Int(EmbeddedModelStore.freeSpaceBytes(at: root) / (1024 * 1024))
        let result = SummaryModelReadiness.evaluate(
            model: model, downloadState: state,
            memoryGB: memoryGB, isAppleSilicon: isAppleSilicon, freeDiskMB: freeMB)
        let needsDownload = state == .notStarted || state == .manifestMismatch
        if needsDownload, case .temporarilyUnavailable = result {
            if removedByUser.contains(model.id) {
                return .temporarilyUnavailable(
                    "\(model.displayName) was removed — download it again in Settings, or choose another summary model.")
            }
            // Never start a multi-GB transfer the user did not ask for in Settings.
            guard optIn.isSet(model.id) else {
                return .temporarilyUnavailable(
                    "\(model.displayName) has not been downloaded — choose Download now in Settings, or pick another summary model.")
            }
            if freeMB >= model.downloadMB * SummaryModelReadiness.diskFactor { launch(model) }
        }
        return result
    }

    func downloadState(_ model: EmbeddedSummaryModel) async -> SummaryModelDownloadState {
        if SummaryModelStore.isVerified(model, root: root) { return .verified }
        if let why = permanentFailures[model.id] { return .failedPermanently(why) }
        if tasks[model.id] != nil { return .inProgress(fraction: fractions[model.id] ?? 0) }
        if await coordinator.manifestFailureCount(id: model.id) > 0 { return .manifestMismatch }
        return .notStarted
    }

    // MARK: Download

    /// The user asked for the download (Settings): start it even if the model
    /// was removed earlier, and clear that flag.
    public func startDownload(_ model: EmbeddedSummaryModel) {
        optIn.set(model.id, true)
        removedByUser.remove(model.id)
        permanentFailures[model.id] = nil
        lastError[model.id] = nil
        launch(model)
    }

    /// Begin a background download unless one is running. Fire-and-forget: the
    /// outcome is observed through `readiness` on a later scan.
    private func launch(_ model: EmbeddedSummaryModel) {
        guard tasks[model.id] == nil else { return }
        fractions[model.id] = 0
        tasks[model.id] = Task { [self] in
            do { try await download(model) } catch {
                if !Task.isCancelled {
                    record(error: (error as? LocalizedError)?.errorDescription ?? "\(error)", for: model.id)
                    await coordinator.report("Downloading \(model.displayName) failed: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
                }
            }
            finished(model.id)
        }
    }

    private func record(error: String, for id: String) { lastError[id] = error }

    private func finished(_ id: String) {
        tasks[id] = nil; fractions[id] = nil
    }

    private func setFraction(_ id: String, _ f: Double) { fractions[id] = f }

    /// Download every catalogue file into a staging folder, verify it against
    /// the generated manifest, then move it into place. Files already complete
    /// in staging (a previous attempt) are not fetched again.
    func download(_ model: EmbeddedSummaryModel) async throws {
        try coordinator.ensureFreeSpace(forMB: model.downloadMB)
        let staging = SummaryModelStore.stagingDirectory(for: model, root: root)
        let final = SummaryModelStore.directory(for: model, root: root)
        let fm = FileManager.default
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        await coordinator.beginDownload(id: model.id)
        await coordinator.report("Downloading \(model.displayName) — \(model.downloadMB) MB download…")
        defer { Task { await coordinator.noteDownload(id: model.id, fraction: nil) } }

        let totalBytes = max(1, model.files.map(\.bytes).reduce(0, +))
        let received = Counter()
        var lastReported = -1
        for file in model.files {
            try Task.checkCancellation()
            let dest = staging.appendingPathComponent(file.path)
            if let size = (try? fm.attributesOfItem(atPath: dest.path))?[.size] as? NSNumber,
               size.int64Value == file.bytes {
                received.add(file.bytes)
                continue
            }
            try? fm.removeItem(at: dest)
            guard let url = model.downloadURL(for: file) else {
                throw RetryableDependencyError("\(model.displayName) has no download location.")
            }
            do {
                try await fetch(url, dest) { [self] n in
                    let done = received.add(n)
                    let fraction = min(1, Double(done) / Double(totalBytes))
                    Task { await self.setFraction(model.id, fraction) }
                }
            } catch {
                if Task.isCancelled { throw CancellationError() }
                throw RetryableDependencyError(
                    "Couldn't download \(model.displayName) (\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)) — Distavo will retry.")
            }
            let pct = Int(Double(received.value) / Double(totalBytes) * 100)
            if pct / 10 != lastReported {
                lastReported = pct / 10
                await coordinator.noteDownload(id: model.id, fraction: Double(pct) / 100)
                await coordinator.report("Downloading \(model.displayName) — \(pct)%")
            }
        }

        // Verify before anything is trusted (spec: a partial or tampered
        // download must not produce a garbled note).
        // Every file is hashed locally right after download (also those resumed
        // from staging), compared to the publisher's SHA-256 where the catalogue
        // has one, and the local hashes go into the manifest — so every file is
        // hash-checked on every later verification, none by size alone.
        try Task.checkCancellation()   // before the do-block: a cancel is not a manifest failure
        do {
            var hashes: [String: String] = [:]
            for file in model.files {
                let local = try ModelManifestCheck.sha256Hex(of: staging.appendingPathComponent(file.path))
                if let published = file.sha256, published != local {
                    throw ModelManifestError.mismatch(file: file.path)
                }
                hashes[file.path] = local
            }
            try model.manifestJSON(sha256ByPath: hashes).write(to: staging.appendingPathComponent("manifest.json"))
            try ModelManifestCheck.verify(folder: staging, expectManifest: true)
        } catch {
            try? fm.removeItem(at: staging)
            let failures = await coordinator.recordManifestFailure(id: model.id)
            if failures >= 2 {
                permanentFailures[model.id] = (error as? LocalizedError)?.errorDescription ?? "checksum mismatch"
            }
            throw error
        }
        try ModelManifestCheck.writeSentinel(folder: staging)
        try? fm.removeItem(at: final)
        try fm.createDirectory(at: final.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: staging, to: final)
        await coordinator.resetManifestFailures(id: model.id)
        await coordinator.report("\(model.displayName) is ready.")
    }

    /// Cancel any in-flight download of `model`, wait for it to unwind (so it
    /// cannot write into a folder we are about to delete), and forget every
    /// failure memory: permanent failure, manifest strikes, load/OOM strikes.
    private func cancelAndForget(_ model: EmbeddedSummaryModel) async {
        if let task = tasks[model.id] {
            task.cancel()
            await task.value
        }
        permanentFailures[model.id] = nil
        fractions[model.id] = nil
        lastError[model.id] = nil
        await coordinator.resetManifestFailures(id: model.id)
        LocalSummaryFailureTracker.shared.noteSuccess(model: model.id)
    }

    /// Delete the downloaded files for `model` (Settings, S6). The model is
    /// not downloaded again behind the user's back; `startDownload` re-enables it.
    public func remove(_ model: EmbeddedSummaryModel) async {
        await cancelAndForget(model)
        optIn.set(model.id, false)
        removedByUser.insert(model.id)
        try? FileManager.default.removeItem(at: SummaryModelStore.directory(for: model, root: root))
        try? FileManager.default.removeItem(at: SummaryModelStore.stagingDirectory(for: model, root: root))
    }

    /// For "Remove downloaded models": stop every download, clear all failure
    /// memory and suppress auto-downloads, so the files `removeAll` deletes are
    /// not recreated by a task that was still running.
    public func cancelAndForgetAll() async {
        for model in EmbeddedSummaryModelCatalog.models where model.engine == .mlx {
            await cancelAndForget(model)
            optIn.set(model.id, false)
            removedByUser.insert(model.id)
        }
    }

    /// The weights failed to load (twice at most before giving up): delete them
    /// so the next readiness check downloads them again, unless that already
    /// happened once — then `permanentMessage` stops the loop for this session.
    func discardWeights(_ model: EmbeddedSummaryModel, permanentMessage: String?) async {
        if let task = tasks[model.id] { task.cancel(); await task.value }
        try? FileManager.default.removeItem(at: SummaryModelStore.directory(for: model, root: root))
        try? FileManager.default.removeItem(at: SummaryModelStore.stagingDirectory(for: model, root: root))
        if let permanentMessage { permanentFailures[model.id] = permanentMessage }
    }
}

/// Thread-safe running byte count for the download callbacks.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var total: Int64 = 0
    @discardableResult func add(_ n: Int64) -> Int64 { lock.withLock { total += n; return total } }
    var value: Int64 { lock.withLock { total } }
}

// MARK: - URLSession fetch

/// Production fetch: a download task whose delegate reports bytes and moves
/// the finished file into place.
@Sendable
func urlSessionFetch(url: URL, destination: URL,
                     onBytes: @escaping @Sendable (Int64) -> Void) async throws {
    let delegate = FileDownloadDelegate(destination: destination, onBytes: onBytes)
    let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
    defer { session.finishTasksAndInvalidate() }
    try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            delegate.continuation = continuation
            session.downloadTask(with: url).resume()
        }
    } onCancel: { session.invalidateAndCancel() }
}

final class FileDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let destination: URL
    let onBytes: @Sendable (Int64) -> Void
    var continuation: CheckedContinuation<Void, Error>?
    private var moveError: Error?

    init(destination: URL, onBytes: @escaping @Sendable (Int64) -> Void) {
        self.destination = destination; self.onBytes = onBytes
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        onBytes(bytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // The temp file is deleted when this returns, so move it now.
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            moveError = URLError(.badServerResponse, userInfo: [
                NSLocalizedDescriptionKey: "server answered HTTP \(http.statusCode)"])
            return
        }
        do { try FileManager.default.moveItem(at: location, to: destination) } catch { moveError = error }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let result = error ?? moveError
        let c = continuation; continuation = nil
        if let result { c?.resume(throwing: result) } else { c?.resume() }
    }
}

// MARK: - Summarise entry point

/// Runs a summarisation with the downloaded Gemma model: pinned prompt recipe
/// (end-of-turn block), the guarded generator, then post-hoc cleanup.
///
/// Holds `ModelCoordinator`'s exclusive lock for the run (about a minute, the
/// weights are being read), so "Remove downloaded models" and Settings
/// downloads wait instead of deleting files mid-read. The pipeline summarises
/// one recording at a time, so this never stalls transcription.
public enum GemmaSummariser {
    /// One generic completion on a downloaded model (Vikunja #2948, "Ask Your
    /// Notes"): the prompt is sent as given, no note post-processing. Exclusive
    /// like `summarise`, so it never overlaps a note generation or a download.
    public static func complete(
        prompt: String, modelID: String, maxOutputTokens: Int,
        root: URL = EmbeddedModelStore.modelsDirectory
    ) async throws -> String {
        try await ModelCoordinator.shared.withExclusiveAccess {
            let model = EmbeddedSummaryModelCatalog.model(id: modelID)
            guard model.engine == .mlx, SummaryModelStore.isVerified(model, root: root) else {
                throw RetryableDependencyError("\(model.displayName) is not downloaded yet.")
            }
            let generator = MLXGemmaGenerator(
                modelDirectory: SummaryModelStore.directory(for: model, root: root), modelID: model.id,
                contextSize: model.contextCap ?? 8192)
            defer { generator.unload() }
            let text = try await generator.generate(prompt, maxOutputTokens: maxOutputTokens)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { throw LocalSummaryError("The local model returned an empty answer.") }
            return text
        }
    }

    public static func summarise(
        transcript: String, modelID: String,
        noteOwner: String, userSpeaker: String, participants: String?,
        style: Prompt.Style, meetingDate: Date?, noteLanguage: String?,
        customInstruction: String? = nil,
        glossary: [String] = [], template: SummaryTemplate? = nil,
        scratchpad: ScratchpadNotes? = nil,
        onProgress: (@Sendable (String) -> Void)? = nil,
        root: URL = EmbeddedModelStore.modelsDirectory,
        manager: SummaryModelManager = .shared
    ) async throws -> String {
        // `root` / `manager` default to the app's real models folder and manager;
        // headless tests inject a temp folder and an isolated manager.
        try await ModelCoordinator.shared.withExclusiveAccess {
            try await run(
                transcript: transcript, modelID: modelID, noteOwner: noteOwner,
                userSpeaker: userSpeaker, participants: participants, style: style,
                meetingDate: meetingDate, noteLanguage: noteLanguage,
                customInstruction: customInstruction, glossary: glossary, template: template, scratchpad: scratchpad,
                onProgress: onProgress,
                root: root, manager: manager)
        }
    }

    private static func run(
        transcript: String, modelID: String,
        noteOwner: String, userSpeaker: String, participants: String?,
        style: Prompt.Style, meetingDate: Date?, noteLanguage: String?,
        customInstruction: String?,
        glossary: [String], template: SummaryTemplate?, scratchpad: ScratchpadNotes?,
        onProgress: (@Sendable (String) -> Void)?,
        root: URL, manager: SummaryModelManager
    ) async throws -> String {
        let model = EmbeddedSummaryModelCatalog.model(id: modelID)
        guard model.engine == .mlx, SummaryModelStore.isVerified(model, root: root) else {
            // Readiness is checked before transcription; this is the race where
            // the files vanished in between — defer, don't fail.
            throw RetryableDependencyError("\(model.displayName) is not downloaded yet.")
        }
        let generator = MLXGemmaGenerator(
            modelDirectory: SummaryModelStore.directory(for: model, root: root), modelID: model.id,
            contextSize: model.contextCap ?? 8192)
        defer { generator.unload() }
        let report: @Sendable (String) -> Void = onProgress ?? { message in
            Task { await ModelCoordinator.shared.report(message) }
        }

        let request = SummaryRequest(
            transcript: transcript, noteOwner: noteOwner, userSpeaker: userSpeaker,
            participants: participants, style: style, meetingDate: meetingDate,
            noteLanguage: noteLanguage,
            endOfTurnBlock: EndOfTurnBlock.build(
                noteLanguage: noteLanguage, style: style, noteOwner: noteOwner,
                ownerSpeaker: userSpeaker, template: template,
                withHighlights: scratchpad?.isEmpty == false),
            customInstruction: customInstruction, glossary: glossary, template: template,
            scratchpad: scratchpad)
        do {
            let raw = try await SummaryDriver.run(request, generator: generator, onProgress: report)
            LocalSummaryFailureTracker.shared.noteSuccess(model: model.id)
            // People the owner named after the recording are real even if nobody
            // said their name aloud.
            return SummaryPostProcess.clean(
                raw, style: style, transcript: transcript, alwaysKeep: [noteOwner],
                extraHaystack: [participants, noteOwner].compactMap { $0 }, template: template)
        } catch let error as SummaryDriverError {
            switch error {
            case .contextTooSmall:
                throw LocalSummaryError("The local summary model's context is too small to summarise anything.")
            case .emptyResult:
                throw LocalSummaryError(LocalSummaryFailurePolicy.decideMessage(for: .emptyOutput))
            case .promptTooLong(let measured, let contextSize):
                throw LocalSummaryError("A section of the recording was too long for the local model (\(measured) tokens vs \(contextSize)).")
            case .outputBudgetTooSmall(let available, let wanted):
                throw LocalSummaryError("A section of the recording left room for only \(available) of the \(wanted) tokens the note needs.")
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Engine errors: classify, count, and decide defer-versus-fail. A
            // model that will not load has its files deleted so the next
            // readiness check downloads them again; twice in a row stops the loop.
            let isLoad = error is GemmaLoadFailure
            let resolution = LocalSummaryFailurePolicy.resolve(
                (error as? GemmaLoadFailure)?.underlying ?? error,
                model: model.id, tracker: .shared, isLoadFailure: isLoad)
            if resolution.discardWeights {
                await manager.discardWeights(
                    model,
                    permanentMessage: resolution.permanent
                        ? (resolution.error as? LocalSummaryError)?.message : nil)
            }
            throw resolution.error
        }
    }
}

// MARK: - Pipeline route

/// The pipeline's summarise step for a downloaded model: the activity-log
/// routing trace, then `GemmaSummariser`. Lives here (not in the app target's
/// `AppPipelineDeps`) so headless tests drive exactly the code the app runs;
/// `root` / `manager` default to the app's real folder and manager.
public enum GemmaPipelineRoute {
    public static func summarise(
        transcript: String, modelID: String, context: NoteContext,
        root: URL = EmbeddedModelStore.modelsDirectory,
        manager: SummaryModelManager = .shared
    ) async throws -> String {
        // Activity-log trace (Vikunja #2198, S6): model, context cap and single
        // pass vs map-reduce, like the transcription routing line.
        await ModelCoordinator.shared.report(SummaryRouting.traceLine(
            model: EmbeddedSummaryModelCatalog.model(id: modelID), transcript: transcript,
            noteOwner: context.noteOwner, userSpeaker: context.userSpeaker,
            style: context.promptStyle, noteLanguage: context.noteLanguage, template: context.template))
        // Unlike Apple's model, Gemma follows the configured prompt style and
        // note language: its window is big enough for facts-first and Catalan/
        // Spanish notes.
        return try await GemmaSummariser.summarise(
            transcript: transcript, modelID: modelID,
            noteOwner: context.noteOwner, userSpeaker: context.userSpeaker,
            participants: context.participants, style: context.promptStyle,
            meetingDate: context.meetingDate, noteLanguage: context.noteLanguage,
            customInstruction: context.customInstruction,
            glossary: context.glossary, template: context.template,
            scratchpad: context.scratchpad, root: root, manager: manager)
    }
}
