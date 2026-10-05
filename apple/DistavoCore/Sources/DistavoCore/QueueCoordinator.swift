import Foundation

// Pause policy and the batch coordinator behind the Processing Queue (#2952).
// Pure and UI-free so the decisions that used to live in app-target closures
// (who may run while paused, retry-jumps-the-line, never-twice, skip) are tested.

/// Who asked for a scan pass.
public enum ScanTrigger: Equatable, Sendable {
    /// The watch-folder timer, or a pass that merely continues a batch.
    case automatic
    /// A deliberate user action: menu/window "Process now", Shortcuts or URL
    /// `process-now`, the Finder Service / Transcribe File intent, enabling local
    /// Ollama, "Retry failed", a single-item Retry.
    case userInitiated
}

/// "Pause watching" holds AUTOMATIC work only.
public enum PausePolicy {
    /// May a pass start now?
    public static func mayStart(_ trigger: ScanTrigger, paused: Bool) -> Bool {
        trigger == .userInitiated || !paused
    }

    /// May a running pass start its NEXT file? Automatic passes stop as soon as
    /// the pause is switched on. A user-initiated pass runs through when it began
    /// while already paused (the user asked for it), but a pause switched on
    /// DURING the pass still holds the next file.
    public static func mayContinue(_ trigger: ScanTrigger, pausedAtStart: Bool, pausedNow: Bool) -> Bool {
        if !pausedNow { return true }
        return trigger == .userInitiated && pausedAtStart
    }
}

/// Owns the retry queue and the never-twice bookkeeping for one app session.
@MainActor
public final class QueueCoordinator {
    /// Recordings the user asked to retry; consumed before the next file.
    public private(set) var retryURLs: [URL] = []
    private let fileExists: (URL) -> Bool

    public init(fileExists: @escaping (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) {
        self.fileExists = fileExists
    }

    public var hasRetries: Bool { !retryURLs.isEmpty }
    public func requestRetry(_ url: URL) { if !retryURLs.contains(url) { retryURLs.append(url) } }
    /// Forget a queued retry (its file was moved to the Bin).
    public func discardRetry(_ url: URL) { retryURLs.removeAll { $0 == url } }

    /// The next retry whose file still exists; vanished ones are dropped, so
    /// `processOne` is never handed a path that is gone.
    func takeRetry() -> URL? {
        while !retryURLs.isEmpty {
            let url = retryURLs.removeFirst()
            if fileExists(url) { return url }
        }
        return nil
    }

    /// One batch: `paths` in scan order, strictly sequential, retries first.
    /// - A file never runs twice in one batch (a retry that is also in `paths`
    ///   runs once, at the retry's turn; a retry of a file already processed
    ///   earlier in the batch does run again).
    /// - `isCancelled` skips a file for the session (it is simply not started).
    /// - Pause is decided per file by `PausePolicy.mayContinue`.
    @discardableResult
    public func run(
        paths: [URL], trigger: ScanTrigger,
        isPaused: () -> Bool,
        isCancelled: (URL) -> Bool,
        begin: (URL) -> Void,
        process: (URL) async -> ProcessResult,
        finished: (URL, ProcessResult) -> Void
    ) async -> Int {
        let pausedAtStart = isPaused()
        var handled = Set<URL>()
        return await QueueScan.run(
            paths: paths,
            shouldContinue: {
                PausePolicy.mayContinue(trigger, pausedAtStart: pausedAtStart, pausedNow: isPaused())
            },
            shouldStart: { url in
                !handled.contains(url) && !self.retryURLs.contains(url) && !isCancelled(url)
            },
            priority: {
                guard let url = self.takeRetry() else { return nil }
                handled.remove(url)
                return url
            },
            begin: { url in handled.insert(url); begin(url) },
            process: process,
            finished: finished)
    }
}
