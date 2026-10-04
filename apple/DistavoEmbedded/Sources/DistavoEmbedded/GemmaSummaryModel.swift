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

    public init() {
        self.init(root: EmbeddedModelStore.modelsDirectory, coordinator: .shared, fetch: urlSessionFetch)
    }

    init(root: URL, coordinator: ModelCoordinator, fetch: @escaping SummaryFileFetch) {
        self.root = root; self.coordinator = coordinator; self.fetch = fetch
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
            memoryGB: Int(HardwareProbe.physicalMemoryBytes / (1024 * 1024 * 1024)),
            isAppleSilicon: HardwareProbe.isAppleSilicon, freeDiskMB: freeMB)
        let needsDownload = state == .notStarted || state == .manifestMismatch
        if needsDownload, case .temporarilyUnavailable = result {
            if removedByUser.contains(model.id) {
                return .temporarilyUnavailable(
                    "\(model.displayName) was removed — download it again in Settings, or choose another summary model.")
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
        removedByUser.remove(model.id)
        permanentFailures[model.id] = nil
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
                    await coordinator.report("Downloading \(model.displayName) failed: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
                }
            }
            finished(model.id)
        }
    }

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
        await coordinator.resetManifestFailures(id: model.id)
        LocalSummaryFailureTracker.shared.noteSuccess(model: model.id)
    }

    /// Delete the downloaded files for `model` (Settings, S6). The model is
    /// not downloaded again behind the user's back; `startDownload` re-enables it.
    public func remove(_ model: EmbeddedSummaryModel) async {
        await cancelAndForget(model)
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
    public static func summarise(
        transcript: String, modelID: String,
        noteOwner: String, userSpeaker: String, participants: String?,
        style: Prompt.Style, meetingDate: Date?, noteLanguage: String?,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        try await ModelCoordinator.shared.withExclusiveAccess {
            try await run(
                transcript: transcript, modelID: modelID, noteOwner: noteOwner,
                userSpeaker: userSpeaker, participants: participants, style: style,
                meetingDate: meetingDate, noteLanguage: noteLanguage, onProgress: onProgress)
        }
    }

    private static func run(
        transcript: String, modelID: String,
        noteOwner: String, userSpeaker: String, participants: String?,
        style: Prompt.Style, meetingDate: Date?, noteLanguage: String?,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws -> String {
        let model = EmbeddedSummaryModelCatalog.model(id: modelID)
        guard model.engine == .mlx, SummaryModelStore.isVerified(model) else {
            // Readiness is checked before transcription; this is the race where
            // the files vanished in between — defer, don't fail.
            throw RetryableDependencyError("\(model.displayName) is not downloaded yet.")
        }
        let generator = MLXGemmaGenerator(
            modelDirectory: SummaryModelStore.directory(for: model), modelID: model.id,
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
                ownerSpeaker: userSpeaker))
        do {
            let raw = try await SummaryDriver.run(request, generator: generator, onProgress: report)
            LocalSummaryFailureTracker.shared.noteSuccess(model: model.id)
            // People the owner named after the recording are real even if nobody
            // said their name aloud.
            return SummaryPostProcess.clean(
                raw, style: style, transcript: transcript, alwaysKeep: [noteOwner],
                extraHaystack: [participants, noteOwner].compactMap { $0 })
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
                await SummaryModelManager.shared.discardWeights(
                    model,
                    permanentMessage: resolution.permanent
                        ? (resolution.error as? LocalSummaryError)?.message : nil)
            }
            throw resolution.error
        }
    }
}
