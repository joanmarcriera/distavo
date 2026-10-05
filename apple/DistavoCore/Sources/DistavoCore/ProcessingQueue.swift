import Foundation

// Processing queue model (Vikunja #2952). Port-free, UI-free, dependency-free.
//
// The queue is a VIEW over durable state, not a second pipeline: the watched
// folder plus the marker files under `workDir/.state` stay the source of truth
// and recordings are still processed one at a time through the app's
// single-flight scan. This file holds
//   * `ProcessingQueue` - a value-type reducer that builds the visible list from
//     (pending files, marker states, live phase callbacks, results), learns a
//     per-stage real-time factor from finished items, and estimates ETAs;
//   * `QueueScan.run` - the sequential per-file loop the scan uses (so pause,
//     per-item skip and "exactly one at a time" are unit-testable);
//   * `QueueRetry` - clear ONE base's retry markers and locate its recording.
//
// Ordering: `DistavoState.iterPending` sorts by full file path (ascending), NOT
// by age. The queue mirrors that: waiting items are listed in path order, which
// is the order the scan will actually process them in.

/// Where an item is in its life. `copying` is a drag-and-drop file still being
/// copied into the recordings folder; `cancelled` means "skipped for this
/// session" (the file stays pending on disk).
public enum QueueItemState: String, Equatable, Sendable, CaseIterable {
    case waiting, copying, converting, transcribing, summarising
    case done, deferred, failed, tooShort, cancelled, skipped

    /// A pipeline stage is executing for this item.
    public var isRunning: Bool {
        self == .converting || self == .transcribing || self == .summarising
    }
}

/// One row of the queue window.
public struct QueueItem: Identifiable, Equatable, Sendable {
    /// `DistavoState.baseFor` of the recording (a `copy:<token>` pseudo-base
    /// while the file is still being copied).
    public var base: String
    /// Absolute path in the recordings folder; nil for a copy that never landed.
    public var sourcePath: String?
    public var displayName: String
    public var state: QueueItemState
    /// 0...1 estimate, only when an ETA could be computed (see `refreshProgress`).
    public var progress: Double?
    public var startedAt: Date?
    public var finishedAt: Date?
    /// Marker reason, pipeline message, or a short explanation.
    public var message: String
    /// How many times the pipeline started on this item this session.
    public var attempts: Int
    /// Seconds of audio, once known (drives the ETA).
    public var durationSeconds: Double?
    /// When the current stage's timer started (first phase callback); nil before.
    public var stageStartedAt: Date?

    public var id: String { base }

    public init(base: String, sourcePath: String?, displayName: String,
                state: QueueItemState = .waiting, progress: Double? = nil,
                startedAt: Date? = nil, finishedAt: Date? = nil,
                message: String = "", attempts: Int = 0,
                durationSeconds: Double? = nil, stageStartedAt: Date? = nil) {
        self.base = base; self.sourcePath = sourcePath; self.displayName = displayName
        self.state = state; self.progress = progress; self.startedAt = startedAt
        self.finishedAt = finishedAt; self.message = message; self.attempts = attempts
        self.durationSeconds = durationSeconds; self.stageStartedAt = stageStartedAt
    }
}

/// A file `iterPending` returned, in scan order.
public struct PendingFile: Equatable, Sendable {
    public var base: String
    public var path: String
    public init(base: String, path: String) { self.base = base; self.path = path }
}

public struct ProcessingQueue: Equatable, Sendable {
    public private(set) var items: [QueueItem] = []
    /// Seconds of work per second of audio, last `rateWindow` samples per stage.
    public private(set) var stageRates: [QueueItemState: [Double]] = [:]
    public static let rateWindow = 5
    /// Most done/skipped rows kept in the list.
    public static let maxFinished = 200
    public static let stages: [QueueItemState] = [.converting, .transcribing, .summarising]
    /// Prefix of the pseudo-base given to a file that is still being copied.
    public static let copyPrefix = "copy:"

    public init() {}

    public func item(_ base: String) -> QueueItem? { items.first { $0.base == base } }
    private func index(_ base: String) -> Int? { items.firstIndex { $0.base == base } }

    // MARK: Disk sync

    /// Reconcile the list with what is on disk. `takenAt` is when the listing
    /// was read: an item the live callbacks touched after that moment is left
    /// alone, so a listing computed off the main actor can never roll back a
    /// result that arrived while it was in flight.
    public mutating func sync(pending: [PendingFile],
                              failed: [(base: String, error: String)],
                              tooShort: [(base: String, reason: String)],
                              takenAt: Date) {
        let pendingByBase = Dictionary(pending.map { ($0.base, $0) }, uniquingKeysWith: { a, _ in a })
        let failedByBase = Dictionary(failed.map { ($0.base, $0.error) }, uniquingKeysWith: { a, _ in a })
        let shortByBase = Dictionary(tooShort.map { ($0.base, $0.reason) }, uniquingKeysWith: { a, _ in a })

        var keep: [QueueItem] = []
        for var item in items {
            let touchedLater = [item.startedAt, item.finishedAt].contains { ($0 ?? .distantPast) > takenAt }
            if item.state.isRunning || item.state == .copying || touchedLater
                || item.base.hasPrefix(Self.copyPrefix) {
                keep.append(item); continue
            }
            switch item.state {
            case .done:
                keep.append(item)                      // stays until "Clear finished"
            case .cancelled:
                if pendingByBase[item.base] != nil { keep.append(item) }   // else file is gone/handled
            case .waiting, .failed, .tooShort, .deferred, .skipped:
                if let p = pendingByBase[item.base] {
                    // Pending on disk again (backoff expired, marker cleared, file changed).
                    if item.state != .waiting { item.message = ""; item.finishedAt = nil }
                    item.state = .waiting; item.sourcePath = p.path
                    keep.append(item)
                } else if let why = failedByBase[item.base] {
                    item.state = .failed; item.message = why; keep.append(item)
                } else if let why = shortByBase[item.base] {
                    item.state = .tooShort; item.message = why; keep.append(item)
                } else if item.state == .deferred {
                    keep.append(item)                  // deferral has no marker when "needs local Ollama"
                }                                       // else resolved elsewhere: drop
            default:
                keep.append(item)
            }
        }
        items = keep
        for p in pending where index(p.base) == nil {
            items.append(QueueItem(base: p.base, sourcePath: p.path,
                                   displayName: (p.path as NSString).lastPathComponent))
        }
        // Failed / too-short recordings that are not pending are shown too, so
        // they can be retried or binned from here.
        for (base, why) in failed where index(base) == nil && pendingByBase[base] == nil {
            items.append(QueueItem(base: base, sourcePath: nil, displayName: base, state: .failed, message: why))
        }
        for (base, why) in tooShort where index(base) == nil && pendingByBase[base] == nil && failedByBase[base] == nil {
            items.append(QueueItem(base: base, sourcePath: nil, displayName: base, state: .tooShort, message: why))
        }
        normalizeOrder()
    }

    /// Non-waiting items keep the order they happened in; waiting items follow,
    /// in scan (path) order.
    private mutating func normalizeOrder() {
        let waiting = items.filter { $0.state == .waiting }
            .sorted { ($0.sourcePath ?? $0.base) < ($1.sourcePath ?? $1.base) }
        items = items.filter { $0.state != .waiting } + waiting
    }

    // MARK: Drag and drop

    public mutating func beginCopy(token: String, displayName: String) {
        items.append(QueueItem(base: Self.copyPrefix + token, sourcePath: nil,
                               displayName: displayName, state: .copying, message: "Copying into the recordings folder"))
    }

    /// The copy finished: drop the pseudo-row (the real file shows up as a
    /// waiting item on the next sync) or, on failure, keep it as a failed row.
    public mutating func finishCopy(token: String, failure: String?, now: Date) {
        guard let i = index(Self.copyPrefix + token) else { return }
        if let failure {
            items[i].state = .failed; items[i].message = failure; items[i].finishedAt = now
        } else {
            items.remove(at: i)
        }
    }

    // MARK: Live callbacks

    /// The scan is about to process `base`. Upserts, so a file that appeared
    /// since the last sync is still tracked.
    /// `displayName` overrides the file name (a variant run shows "name @model-lang").
    public mutating func begin(base: String, sourcePath: String, displayName: String? = nil, now: Date) {
        if index(base) == nil {
            items.append(QueueItem(base: base, sourcePath: sourcePath,
                                   displayName: displayName ?? (sourcePath as NSString).lastPathComponent))
        }
        guard let i = index(base) else { return }
        items[i].state = .converting
        items[i].sourcePath = sourcePath
        items[i].startedAt = now
        items[i].finishedAt = nil
        items[i].stageStartedAt = nil      // timing starts at the first phase callback
        items[i].progress = nil
        items[i].message = "Preparing"
        items[i].attempts += 1
        normalizeOrder()
    }

    public mutating func setDuration(base: String, seconds: Double) {
        guard seconds > 0, let i = index(base) else { return }
        items[i].durationSeconds = seconds
    }

    /// A pipeline stage boundary for the item that is running.
    public mutating func phase(_ phase: ProcessingPhase, now: Date) {
        guard let i = items.firstIndex(where: { $0.state.isRunning }) else { return }
        recordSample(items[i], now: now)
        switch phase {
        case .converting: items[i].state = .converting
        case .transcribing: items[i].state = .transcribing
        case .summarising: items[i].state = .summarising
        }
        items[i].stageStartedAt = now
        items[i].message = ""
    }

    /// A pipeline result. Results for bases the queue does not track (variant
    /// runs, regenerate) are ignored.
    public mutating func finish(_ result: ProcessResult, now: Date) {
        guard let i = index(result.base) else { return }
        switch result.status {
        case .done:
            recordSample(items[i], now: now)        // closes the summarising stage
            items[i].state = .done; items[i].progress = 1
        case .skipped: items[i].state = .skipped
        case .deferred, .deferredNeedLocal: items[i].state = .deferred
        case .failed: items[i].state = .failed
        case .tooShort: items[i].state = .tooShort
        }
        items[i].message = result.message
        items[i].finishedAt = now
        items[i].stageStartedAt = nil
        if result.status != .done { items[i].progress = nil }
        trimFinished()
    }

    /// Keep a long session bounded: only the newest `maxFinished` done/skipped
    /// rows stay (disk-backed failed/too-short/deferred rows are never trimmed).
    private mutating func trimFinished() {
        let finished = items.indices.filter { items[$0].state == .done || items[$0].state == .skipped }
        guard finished.count > Self.maxFinished else { return }
        let drop = Set(finished.prefix(finished.count - Self.maxFinished))
        items = items.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
    }

    /// Feed the rolling rate for the stage `item` was in, when it ran to completion.
    private mutating func recordSample(_ item: QueueItem, now: Date) {
        guard Self.stages.contains(item.state), let started = item.stageStartedAt,
              let d = item.durationSeconds, d > 0 else { return }
        let elapsed = now.timeIntervalSince(started)
        guard elapsed > 0 else { return }
        var rates = stageRates[item.state] ?? []
        rates.append(elapsed / d)
        if rates.count > Self.rateWindow { rates.removeFirst(rates.count - Self.rateWindow) }
        stageRates[item.state] = rates
    }

    // MARK: Actions

    /// Only a waiting item can be cancelled: there is no safe cancellation point
    /// inside `Pipeline.processOne` (see the controller notes), so a running
    /// item cannot be.
    public func canCancel(_ base: String) -> Bool { item(base)?.state == .waiting }

    /// Skip a waiting item for this session. It stays pending on disk.
    @discardableResult
    public mutating func cancel(base: String) -> Bool {
        guard let i = index(base), items[i].state == .waiting else { return false }
        items[i].state = .cancelled
        items[i].message = "Skipped for this session - still in the folder, offered again at next launch"
        return true
    }

    @discardableResult
    public mutating func restore(base: String) -> Bool {
        guard let i = index(base), items[i].state == .cancelled else { return false }
        items[i].state = .waiting; items[i].message = ""
        normalizeOrder()
        return true
    }

    /// Mark a failed/deferred item as queued again (the markers are cleared by `QueueRetry`).
    @discardableResult
    public mutating func markRetrying(base: String) -> Bool {
        guard let i = index(base), items[i].state == .failed || items[i].state == .deferred else { return false }
        items[i].state = .waiting; items[i].message = "Retrying"; items[i].finishedAt = nil
        normalizeOrder()
        return true
    }

    /// Remove an item from the list (file moved to the Bin, say).
    public mutating func remove(base: String) { items.removeAll { $0.base == base } }

    /// Drop completed rows: done, skipped, and copy failures (which have no
    /// marker). Failed / too-short / deferred rows come from disk and would
    /// only reappear, so they stay.
    public mutating func clearFinished() {
        items.removeAll { $0.state == .done || $0.state == .skipped || ($0.state == .failed && $0.sourcePath == nil && $0.base.hasPrefix(Self.copyPrefix)) }
    }

    // MARK: ETA

    /// Mean of the recent samples for `stage`, or nil with no data yet.
    public func rate(_ stage: QueueItemState) -> Double? {
        guard let r = stageRates[stage], !r.isEmpty else { return nil }
        return r.reduce(0, +) / Double(r.count)
    }

    /// Seconds still to go for `item`, or nil when it cannot be said honestly
    /// (unknown duration, or a stage this session has not yet measured).
    public func eta(for item: QueueItem, now: Date) -> TimeInterval? {
        guard let d = item.durationSeconds, d > 0 else { return nil }
        let stages = Self.stages
        var firstFull: Int            // index of the first stage counted in full
        var total = 0.0
        switch item.state {
        case .waiting, .copying: firstFull = 0
        case .converting, .transcribing, .summarising:
            guard let s = stages.firstIndex(of: item.state), let r = rate(item.state) else { return nil }
            let elapsed = item.stageStartedAt.map { now.timeIntervalSince($0) } ?? 0
            total += max(0, r * d - elapsed)
            firstFull = s + 1
        default: return nil
        }
        for stage in stages[firstFull...] {
            guard let r = rate(stage) else { return nil }
            total += r * d
        }
        return total
    }

    /// ETA for everything not yet finished, nil unless every such item has one.
    public func totalETA(now: Date) -> TimeInterval? {
        let open = items.filter { $0.state == .waiting || $0.state.isRunning }
        guard !open.isEmpty else { return nil }
        var sum = 0.0
        for item in open {
            guard let e = eta(for: item, now: now) else { return nil }
            sum += e
        }
        return sum
    }

    /// Fill `progress` for running items from the ETA (nil without data).
    public mutating func refreshProgress(now: Date) {
        for i in items.indices where items[i].state.isRunning {
            guard let started = items[i].startedAt, let remaining = eta(for: items[i], now: now) else {
                items[i].progress = nil; continue
            }
            let elapsed = max(0, now.timeIntervalSince(started))
            let total = elapsed + remaining
            items[i].progress = total > 0 ? min(0.97, elapsed / total) : nil
        }
    }

    /// "about 3 min" / "under a minute" / "about 1 h 20 min".
    public static func etaLabel(_ seconds: TimeInterval) -> String {
        if seconds < 45 { return "under a minute" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "about \(max(1, minutes)) min" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "about \(h) h" : "about \(h) h \(m) min"
    }
}

/// The sequential per-file loop shared by the timer scan and single-file retry.
public enum QueueScan {
    /// Process `paths` strictly one after another. `shouldContinue` is asked
    /// before EACH file (pause: the current file finishes, the next never
    /// starts); `shouldStart` skips an individual file (cancelled for this
    /// session). `priority` is polled before each file and, when it yields a
    /// URL, that file runs next - this is how a retry jumps the line without a
    /// rescan. Returns the number of files handed to `process`.
    @MainActor
    @discardableResult
    public static func run(
        paths: [URL],
        shouldContinue: () -> Bool,
        shouldStart: (URL) -> Bool = { _ in true },
        priority: () -> URL? = { nil },
        begin: (URL) -> Void,
        process: (URL) async -> ProcessResult,
        finished: (URL, ProcessResult) -> Void
    ) async -> Int {
        var started = 0
        var next = 0
        while shouldContinue() {
            let path: URL
            if let p = priority() { path = p }
            else if next < paths.count { path = paths[next]; next += 1 }
            else { break }
            guard shouldStart(path) else { continue }
            begin(path)
            started += 1
            let result = await process(path)
            finished(path, result)
        }
        return started
    }
}

/// "Retry this one file" - touches only the named base.
public enum QueueRetry {
    /// Clear the `.failed` marker and any `.deferred` backoff of `base` ONLY,
    /// then locate its recording. Other bases' markers are left alone (unlike
    /// "Process now", which clears all of them). Nil when the file is gone.
    public static func prepare(base: String, recordingsDir: URL, store: DistavoState.Store,
                               locate: (String, URL) -> URL? = QueueRetry.locate) -> URL? {
        store.clearFailed(base)
        store.clearDeferred(base)
        return locate(base, recordingsDir)
    }

    /// The recording whose `baseFor` is `base` (bases are one-way, so walk the folder).
    public static func locate(base: String, in recordingsDir: URL) -> URL? {
        guard let en = FileManager.default.enumerator(
            at: recordingsDir, includingPropertiesForKeys: [.isRegularFileKey]) else { return nil }
        for case let url as URL in en {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  QueuedFile.isSupportedMedia(url.lastPathComponent) else { continue }
            if DistavoState.baseFor(recordingsDir: recordingsDir, path: url) == base { return url }
        }
        return nil
    }
}
