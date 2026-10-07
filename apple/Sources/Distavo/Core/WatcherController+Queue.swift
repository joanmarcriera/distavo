import AppKit
import Combine
import DistavoCore

// Processing Queue (Vikunja #2952): controller side.
//
// The queue is a VIEW over the durable state (watched folder + marker files)
// plus live phase/result callbacks. It is not a second pipeline: files are still
// processed one at a time through the controller's single-flight scan
// (`isScanning`). This file holds
//   * `QueueModel`  - the observable wrapper around DistavoCore's `ProcessingQueue`
//                     reducer, with UI publishing throttled to ~4 Hz;
//   * the extension - scan loop, pause, per-item skip, single-file retry (jumps
//                     the line, no folder rescan, other failed markers untouched),
//                     reprocess via the EXISTING variant mechanism, drag-and-drop
//                     intake that reuses `queueForTranscription` (serial copies).
//
// Cancel: only a WAITING item can be skipped (for this session). A running item
// cannot: `Pipeline.processOne` has no cancellation point - it writes a
// `.processing` marker, hands a non-cancellable engine call to WhisperKit /
// WhisperX / Ollama, and treats any thrown error as a permanent `.failed`.
// Cancelling the Task would therefore risk a stuck marker or a bogus failure, so
// the UI disables the control and says so instead of faking it.

/// What a background read of the folder + markers returned.
struct QueueDiskSnapshot {
    var pending: [PendingFile]
    var failed: [(base: String, error: String)]
    var tooShort: [(base: String, reason: String)]
    var durations: [String: Double]
    var unreadable: [String] = []
}

@MainActor
final class QueueModel: ObservableObject {
    /// Last published state (throttled).
    @Published private(set) var queue = ProcessingQueue()
    /// A one-line problem report for the last drop (rejected folders, wrong types).
    @Published var notice: String?

    private var working = ProcessingQueue()
    private var lastPublish = Date.distantPast
    private var publishScheduled = false
    private static let publishInterval = 0.25   // ~4 Hz

    /// Retry queue + never-twice bookkeeping (DistavoCore, unit-tested).
    let coordinator = QueueCoordinator()
    /// Files whose duration could not be read: not probed again every refresh.
    private var unreadableDurations: Set<String> = []
    /// Serialises drag-and-drop copies across drops.
    var copyChain: Task<Void, Never>?
    private var copyCounter = 0

    func mutate(_ body: (inout ProcessingQueue) -> Void) {
        body(&working)
        schedulePublish()
    }

    private func schedulePublish() {
        let since = Date().timeIntervalSince(lastPublish)
        if since >= Self.publishInterval { publishNow(); return }
        guard !publishScheduled else { return }
        publishScheduled = true
        let wait = Self.publishInterval - since
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            self?.publishScheduled = false
            self?.publishNow()
        }
    }

    private func publishNow() {
        working.refreshProgress(now: Date())
        queue = working
        lastPublish = Date()
    }

    // MARK: Hooks called by WatcherController

    func phase(_ phase: ProcessingPhase) { mutate { $0.phase(phase, now: Date()) } }
    func finish(_ result: ProcessResult) { mutate { $0.finish(result, now: Date()) } }

    func begin(base: String, path: String, displayName: String? = nil) {
        mutate { $0.begin(base: base, sourcePath: path, displayName: displayName, now: Date()) }
        guard working.item(base)?.durationSeconds == nil else { return }
        let url = URL(fileURLWithPath: path)
        Task.detached(priority: .utility) { [weak self] in
            let seconds = AudioConverter.durationSeconds(of: url)
            await MainActor.run {
                guard let seconds else { self?.unreadableDurations.insert(base); return }
                self?.mutate { $0.setDuration(base: base, seconds: seconds) }
            }
        }
    }

    func isCancelled(base: String) -> Bool { working.item(base)?.state == .cancelled }
    func item(_ base: String) -> QueueItem? { working.item(base) }
    /// Bases whose duration is known or hopeless (unreadable): skip probing them.
    var knownDurationBases: Set<String> {
        Set(working.items.filter { $0.durationSeconds != nil }.map(\.base)).union(unreadableDurations)
    }

    func apply(_ snap: QueueDiskSnapshot, takenAt: Date) {
        mutate {
            $0.sync(pending: snap.pending, failed: snap.failed, tooShort: snap.tooShort, takenAt: takenAt)
            for (base, seconds) in snap.durations { $0.setDuration(base: base, seconds: seconds) }
        }
        unreadableDurations.formUnion(snap.unreadable)
    }

    // MARK: Regenerate rows (1.18)

    /// False when a regenerate of that note is already waiting or running.
    func enqueueRegenerate(base: String, title: String) -> Bool {
        var accepted = false
        mutate { accepted = $0.enqueueRegenerate(base: base, title: title) }
        return accepted
    }
    func beginRegenerate(base: String) { mutate { $0.beginRegenerate(base: base, now: Date()) } }
    func finishRegenerate(base: String, done: Bool, message: String) {
        mutate { $0.finishRegenerate(base: base, done: done, message: message, now: Date()) }
    }

    // MARK: Copy rows

    func beginCopy(displayName: String) -> String {
        copyCounter += 1
        let token = String(copyCounter)
        mutate { $0.beginCopy(token: token, displayName: displayName) }
        return token
    }
}

extension WatcherController {

    // MARK: Scan loop

    /// The per-file loop of `scanOnce`, delegated to `QueueCoordinator`: strictly
    /// sequential, pause decided per file by `PausePolicy`, files skipped for this
    /// session not started, queued retries run before the next file, no file twice.
    func runQueueLoop(_ pending: [URL], config cfg: Config, trigger: ScanTrigger) async {
        let recordingsDir = Config.resolvePath(cfg.recordingsDir)
        func baseOf(_ url: URL) -> String { DistavoState.baseFor(recordingsDir: recordingsDir, path: url) }
        await queueModel.coordinator.run(
            paths: pending, trigger: trigger,
            isPaused: { self.isPaused },
            isCancelled: { self.queueModel.isCancelled(base: baseOf($0)) },
            begin: { url in
                self.setStatus("Processing \(url.lastPathComponent)…")
                self.log("Processing \(url.lastPathComponent)")
                self.queueModel.begin(base: baseOf(url), path: url.path)
            },
            process: { await Pipeline.processOne(path: $0, config: cfg, deps: self.deps) },
            finished: { url, result in self.handle(result, sourcePath: url) })
    }

    /// Show a variant run (Reprocess…, "Process a recording with…") as a row.
    func queueBeginVariant(_ variant: ProcessVariant, on url: URL) {
        let recordingsDir = Config.resolvePath(config.recordingsDir)
        let base = variant.base(for: DistavoState.baseFor(recordingsDir: recordingsDir, path: url))
        queueModel.begin(base: base, path: url.path,
                         displayName: "\(url.lastPathComponent) @ \(variant.suffix)")
    }

    // MARK: Disk view

    /// Re-read pending files and markers off the main actor, then reconcile.
    func refreshQueue() async {
        let cfg = config
        let known = queueModel.knownDurationBases
        let takenAt = Date()
        let snapshot = await Task.detached(priority: .utility) { () -> QueueDiskSnapshot? in
            let recordings = Config.resolvePath(cfg.recordingsDir)
            guard let store = try? DistavoState.Store(
                stateDir: Config.resolvePath(cfg.workDir).appendingPathComponent(".state"),
                notesDir: Config.resolvePath(cfg.notesDir)) else { return nil }
            let urls = DistavoState.iterPending(recordingsDir: recordings, state: store)
            var pending: [PendingFile] = []
            var durations: [String: Double] = [:]
            var unreadable: [String] = []
            for url in urls {
                let base = DistavoState.baseFor(recordingsDir: recordings, path: url)
                pending.append(PendingFile(base: base, path: url.path))
                if !known.contains(base) {
                    if let d = AudioConverter.durationSeconds(of: url) { durations[base] = d } else { unreadable.append(base) }
                }
            }
            return QueueDiskSnapshot(pending: pending, failed: store.failedBases(),
                                     tooShort: store.tooShortBases(), durations: durations, unreadable: unreadable)
        }.value
        guard let snapshot else { return }
        queueModel.apply(snapshot, takenAt: takenAt)
    }

    func showProcessingQueue() {
        QueueWindowController.shared.show(self)
        Task { await refreshQueue() }
    }

    // MARK: Pause

    /// Same flag as the menu's "Pause watching": the timer stops starting scans and a
    /// running batch stops between files. Pause holds AUTOMATIC work only: "Process
    /// now", Retry and the automation entry points still run. Session-only.
    func toggleQueuePause() {
        togglePause()
        if !isPaused { Task { await scanOnce() } }
    }

    // MARK: Per-item actions

    /// Skip a waiting file for this session. It stays pending on disk.
    func cancelQueueItem(_ base: String) {
        queueModel.mutate { $0.cancel(base: base) }
        log("Skipped for this session: \(base)")
    }

    func restoreQueueItem(_ base: String) {
        queueModel.mutate { $0.restore(base: base) }
    }

    func clearFinishedQueueItems() { queueModel.mutate { $0.clearFinished() } }

    /// Retry ONE failed/deferred recording: clear only its markers, queue it to
    /// run next. No folder rescan; other failed recordings stay failed.
    func retryQueueItem(_ base: String) {
        guard !base.contains("@"), let store = store(),
              let state = queueModel.item(base)?.state, state == .failed || state == .deferred else { return }
        let recordingsDir = Config.resolvePath(config.recordingsDir)
        guard let url = QueueRetry.prepare(base: base, recordingsDir: recordingsDir, store: store) else {
            log("Cannot retry \(base): the recording is no longer in the folder")
            queueModel.mutate { $0.remove(base: base) }
            refreshFailedRecordings()
            return
        }
        queueModel.mutate { _ = $0.markRetrying(base: base) }
        queueModel.coordinator.requestRetry(url)
        log("Retrying \(url.lastPathComponent)")
        refreshFailedRecordings()
        // User-initiated: runs even while paused. A running batch takes the retry before
        // its next file; otherwise this one-file pass does (no folder rescan).
        Task { await runRetryBatch() }
    }

    /// Process only the queued retries (no folder listing), under the scan lock.
    private func runRetryBatch() async {
        await runExclusivePass(onlyIf: { self.queueModel.coordinator.hasRetries }) {
            await runQueueLoop([], config: config, trigger: .userInitiated)
        }
        await refreshQueue()
    }

    /// "Reprocess with…": the existing model/language sheet and variant run
    /// (the note lands beside the normal one as `<base>@<model>-<lang>.md`).
    func reprocessQueueItem(_ base: String) {
        guard !base.contains("@"), let url = queueSourceURL(base),
              let variant = chooseVariant(for: url) else { return }
        Task { await runVariant(variant, on: url) }
    }

    func queueSourceURL(_ base: String) -> URL? {
        if let path = queueModel.item(base)?.sourcePath, FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return QueueRetry.locate(base: base, in: Config.resolvePath(config.recordingsDir))
    }

    func revealQueueItem(_ base: String) {
        guard let url = queueSourceURL(base) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openQueueNote(_ base: String) {
        guard let note = store()?.notePath(base), FileManager.default.fileExists(atPath: note.path) else {
            queueModel.notice = "No note for \(base) yet."
            return
        }
        NSWorkspace.shared.open(note)
    }

    /// Move the recording to the Bin (recoverable) and forget its markers.
    func trashQueueItem(_ base: String) {
        guard !base.contains("@"), let url = queueSourceURL(base),
              queueModel.item(base)?.state.isRunning != true else { return }
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            queueModel.coordinator.discardRetry(url)   // a trashed file must never be handed to processOne
            if let store = store() { store.clearFailed(base); store.clearTooShort(base); store.clearDeferred(base) }
            queueModel.mutate { $0.remove(base: base) }
            log("Moved to the Bin from the queue: \(url.lastPathComponent)")
            refreshFailedRecordings()
        } catch {
            queueModel.notice = "Could not move \(url.lastPathComponent) to the Bin: \(error.localizedDescription)"
        }
    }

    // MARK: Drag and drop

    /// Files dropped on the queue window. Each is validated, shown as `copying`,
    /// and copied into the recordings folder through the SAME helper Shortcuts and
    /// the Finder Service use (`queueForTranscription`: unique names, `.distavo-copy`
    /// temp, background copy). Copies run one after another, across drops, so 20
    /// files never mean 20 concurrent copies; the main thread only awaits.
    func enqueueDrop(_ urls: [URL]) {
        var accepted: [(url: URL, scoped: Bool)] = []
        var problems: [String] = []
        for url in urls {
            // Dropped URLs are readable for the drop; keep access open until copied.
            let scoped = url.startAccessingSecurityScopedResource()
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            if isDirectory {
                problems.append("\(url.lastPathComponent): folders are not supported - drop the files inside it")
            } else if !QueuedFile.isSupportedMedia(url.lastPathComponent) {
                problems.append("\(url.lastPathComponent): not a supported audio or video file")
            } else {
                accepted.append((url, scoped))
                continue
            }
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        queueModel.notice = problems.isEmpty ? nil : problems.joined(separator: "\n")
        guard !accepted.isEmpty else { return }
        let tokens = accepted.map { queueModel.beginCopy(displayName: $0.url.lastPathComponent) }

        let previous = queueModel.copyChain
        queueModel.copyChain = Task { @MainActor [weak self] in
            await previous?.value
            for (i, entry) in accepted.enumerated() {
                guard let self else { return }
                var failure: String?
                do {
                    _ = try await self.queueForTranscription(
                        source: entry.url, data: nil, name: entry.url.lastPathComponent,
                        releaseScope: entry.scoped)
                } catch {
                    failure = String(localized: (error as? AutomationError)?.localizedStringResource
                                     ?? "The file could not be copied.")
                }
                self.queueModel.mutate { $0.finishCopy(token: tokens[i], failure: failure, now: Date()) }
                await self.refreshQueue()
            }
        }
    }
}
