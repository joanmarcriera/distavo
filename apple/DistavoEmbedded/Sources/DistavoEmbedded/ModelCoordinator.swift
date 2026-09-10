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

    public func noteDownload(id: String, fraction: Double?) {
        if let f = fraction { downloading[id] = f } else { downloading[id] = nil }
    }

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
}
