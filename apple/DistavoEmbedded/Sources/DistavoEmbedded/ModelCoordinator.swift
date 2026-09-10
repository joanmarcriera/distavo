import Foundation
import DistavoCore

public enum ModelReadiness: Equatable, Sendable {
    case absent
    case downloading(fraction: Double)
    case ready
}

/// One owner for every model operation on disk (spec §5.8): serialises
/// downloads, transcriptions and "Remove downloaded models" so a timer scan and
/// "Download now" can never run the same download twice or delete a folder an
/// engine is reading, and funnels progress into one handler.
public actor ModelCoordinator {
    public static let shared = ModelCoordinator()

    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var progressHandler: (@Sendable (String) -> Void)?
    private var downloading: [String: Double] = [:]
    private var cancelRequested = false

    public init() {}

    public func setProgressHandler(_ handler: (@Sendable (String) -> Void)?) { progressHandler = handler }
    public func report(_ message: String) { progressHandler?(message) }

    public func readiness(of id: String) -> ModelReadiness {
        if let f = downloading[id] { return .downloading(fraction: f) }
        if id == EmbeddedModelCatalog.automaticID { return .ready }
        return EmbeddedModelStore.isDownloaded(EmbeddedModelCatalog.model(id: id)) ? .ready : .absent
    }

    /// Start tracking a download. Progress fractions are only recorded for ids
    /// that were begun and not yet finished, so a callback that lands after the
    /// terminal reset cannot resurrect a "downloading" state (Task 11 review).
    public func beginDownload(id: String) { downloading[id] = 0 }

    /// Record progress (`fraction` non-nil) or clear it (`nil`, the terminal
    /// reset on both the success and failure path). A non-nil fraction is only
    /// applied while `id` is already being tracked (via `beginDownload`) — a
    /// progress callback that races past the terminal reset is silently
    /// ignored instead of re-inserting a stale "downloading" entry that
    /// nothing would ever clear again.
    public func noteDownload(id: String, fraction: Double?) {
        guard let f = fraction else { downloading[id] = nil; return }
        if downloading[id] != nil { downloading[id] = f }
    }

    /// Ask `prefetch` to stop before its next model. Neither WhisperKit's nor
    /// FluidAudio's download call takes a cancellation token, so a model already
    /// downloading when this is called still runs to completion — cancellation
    /// only takes effect at the next check point (before the detector, and
    /// before each subsequent model). Callers should tell the user their
    /// request is queued ("Cancelling after the current model…"), not that it
    /// already happened.
    public func cancelDownloads() { cancelRequested = true }
    public func consumeCancel() -> Bool { defer { cancelRequested = false }; return cancelRequested }

    /// Run `body` as the only model operation in flight.
    public func withExclusiveAccess<T>(_ body: @Sendable () async throws -> T) async throws -> T {
        while busy { await withCheckedContinuation { waiters.append($0) } }
        busy = true
        defer {
            busy = false
            if !waiters.isEmpty { waiters.removeFirst().resume() }
        }
        return try await body()
    }

    /// Refuse to start a download the disk cannot hold twice over (staging +
    /// final). Free space changes, so the error is retryable.
    public nonisolated func ensureFreeSpace(forMB mb: Int) throws {
        let need = Int64(mb) * 2 * 1024 * 1024
        if EmbeddedModelStore.freeSpaceBytes() < need {
            throw RetryableDependencyError("Not enough free disk space to download \(mb) MB of models — free some space and Distavo will retry.")
        }
    }

    /// Delete every downloaded model once nothing is using them.
    public func removeAllModels() async throws {
        try await withExclusiveAccess { try EmbeddedModelStore.removeAll() }
    }

    /// Download (without loading) the detector and the given catalog models.
    /// Used by Settings' "Download now" so the first meeting never waits.
    ///
    /// `withExclusiveAccess`'s `body` is `@Sendable`, so it does not inherit this
    /// actor's isolation — every actor-isolated call inside it (all but the
    /// `nonisolated` `ensureFreeSpace`) needs an explicit `await`.
    public func prefetch(ids: [String], includeDetector: Bool,
                         download: @Sendable (EmbeddedModel?) async throws -> Void) async throws -> PrefetchOutcome {
        try await withExclusiveAccess {
            // Checked before the detector too — a cancel requested while queued
            // behind another operation must stop the whole prefetch, not just
            // the catalog-model loop.
            if await self.consumeCancel() { return .cancelled }
            if includeDetector, !EmbeddedModelStore.isDetectorDownloaded() { try await download(nil) }
            for id in ids {
                let model = EmbeddedModelCatalog.model(id: id)
                guard !EmbeddedModelStore.isDownloaded(model) else { continue }
                try self.ensureFreeSpace(forMB: model.downloadMB)
                if await self.consumeCancel() { return .cancelled }
                // Prime tracking (Task 11 ruling: fractions for untracked ids are ignored),
                // report, download, and always reset — on throw too.
                await self.beginDownload(id: model.id)
                await self.report("Downloading \(model.displayName) — \(model.downloadLabel)…")
                do { try await download(model) } catch { await self.noteDownload(id: model.id, fraction: nil); throw error }
                await self.noteDownload(id: model.id, fraction: nil)
            }
            return .completed
        }
    }
}

/// Whether a `prefetch` call ran to completion or stopped early because
/// `cancelDownloads()` was called — distinct outcomes so the caller can tell
/// "Ready" (everything requested is on disk) from "stopped partway, but what
/// downloaded before the cancel is kept".
public enum PrefetchOutcome: Equatable, Sendable {
    case completed
    case cancelled
}
