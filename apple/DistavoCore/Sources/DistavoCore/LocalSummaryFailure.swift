import Foundation

// Failure taxonomy for the local (MLX Gemma) summary engine (Vikunja #2198, S4).
// Pure functions of an error message, so the defer-or-fail decision is unit-
// tested without a GPU. Mirrors the rule already used for Apple's model and
// Ollama: a transient condition defers (RetryableDependencyError), a condition
// that will not fix itself fails once with guidance. Anything unrecognised
// gets one deferral before it is allowed to fail permanently — a failed base is
// never retried, so the first surprise must not be final.
//
// Caveat recorded in the brainstorm (open item 9): a RetryableDependencyError
// thrown during summarise makes the next attempt re-transcribe the recording,
// so generate-time deferral is expensive — hence at most one or two retries.

public enum LocalSummaryFailureKind: Equatable, Sendable {
    /// Metal/MLX could not allocate (another GPU app busy, memory pressure).
    case outOfMemory
    /// A Metal/GPU command-buffer error (timeout, discarded, aborted): transient.
    case gpuError
    /// The stream looped again after the one temperature-bumped retry.
    case repetitionCollapse
    /// Weights/tokenizer files missing or corrupt on disk.
    case weightsUnreadable
    /// The model produced no text.
    case emptyOutput
    case other(String)

    /// Counter key: the associated message of `.other` is ignored so every
    /// unclassified error shares one two-strike count.
    var key: String {
        switch self {
        case .outOfMemory: return "oom"
        case .gpuError: return "gpu"
        case .repetitionCollapse: return "loop"
        case .weightsUnreadable: return "unreadable"
        case .emptyOutput: return "empty"
        case .other: return "other"
        }
    }
}

public enum LocalSummaryFailureDecision: Equatable, Sendable {
    /// Defer: the recording stays pending and is retried with backoff.
    case retryable(String)
    /// Fail once, with a message that tells the user what to do.
    case fail(String)
}

/// What the engine should do about an error.
public struct LocalSummaryResolution {
    /// The error to throw: `RetryableDependencyError` defers, anything else fails.
    public let error: Error
    /// Delete the downloaded weights so the next readiness check downloads them again.
    public let discardWeights: Bool
    /// Stop offering the model this session (it failed to load twice in a row).
    public let permanent: Bool
}

public enum LocalSummaryFailurePolicy {

    /// Map an engine error message onto a kind. Matching is case-insensitive
    /// and deliberately broad: MLX surfaces Metal errors as free text.
    public static func classify(message: String) -> LocalSummaryFailureKind {
        let m = message.lowercased()
        let oom = ["out of memory", "outofmemory", "insufficient memory", "failed to allocate",
                   "attempting to allocate"]
        if oom.contains(where: m.contains) { return .outOfMemory }
        let gpu = ["command buffer", "commandbuffer", "kiogpucommandbuffer", "gpu timeout",
                   "gpu error", "mtlcommandbuffer", "[metal]"]
        if gpu.contains(where: m.contains) { return .gpuError }
        let unreadable = ["no safetensors", "unable to load weights", "is corrupt", "missing tokenizer",
                          "missing config", "could not load model", "no such file"]
        if unreadable.contains(where: m.contains) { return .weightsUnreadable }
        return .other(message)
    }

    /// `prior` = how many times in a row this kind has already happened for
    /// the model (0 on the first).
    public static func decide(_ kind: LocalSummaryFailureKind, _ prior: Int) -> LocalSummaryFailureDecision {
        switch kind {
        case .outOfMemory:
            if prior == 0 {
                return .retryable("The Mac ran short of memory while summarising — Distavo will try again shortly.")
            }
            return .fail("The local summary model ran out of memory twice in a row. Close other heavy apps, "
                         + "or switch summaries to Apple Intelligence or Ollama in Settings.")
        case .gpuError:
            if prior < 2 {
                return .retryable("The GPU reported a temporary error while summarising — Distavo will try again shortly.")
            }
            return .fail("The GPU kept failing while summarising. Restart the Mac, or switch summaries to "
                         + "Apple Intelligence or Ollama in Settings.")
        case .weightsUnreadable:
            if prior == 0 {
                return .retryable("The local summary model's files are unreadable — Distavo will download them again.")
            }
            return .fail("The local summary model's files were unreadable twice in a row, even after downloading "
                         + "them again. Switch summaries to Apple Intelligence or Ollama in Settings.")
        case .repetitionCollapse:
            return .fail("The local summary model got stuck repeating itself, even after a retry. "
                         + "Try again later, or use Ollama in Settings.")
        case .emptyOutput:
            return .fail("The local summary model produced no text.")
        case .other(let message):
            if prior == 0 {
                return .retryable("Local summarisation hit an unexpected error (\(message)) — Distavo will try once more.")
            }
            return .fail("Local summarisation failed: \(message)")
        }
    }

    /// The user-facing message of a permanent decision for `kind`.
    public static func decideMessage(for kind: LocalSummaryFailureKind) -> String {
        switch decide(kind, 2) {
        case .retryable(let m), .fail(let m): return m
        }
    }

    /// Classify + decide + record. `isLoadFailure` marks an error thrown while
    /// loading the model: one that is not otherwise recognised is treated as
    /// unreadable weights (discard and download again, once).
    public static func resolve(_ error: Error, model: String, tracker: LocalSummaryFailureTracker,
                               isLoadFailure: Bool = false) -> LocalSummaryResolution {
        // Already a decision (loop collapse, a deferral from deeper down).
        if error is LocalSummaryError || error is RetryableDependencyError {
            return LocalSummaryResolution(error: error, discardWeights: false, permanent: false)
        }
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        var kind = classify(message: message)
        if isLoadFailure, case .other = kind { kind = .weightsUnreadable }
        let prior = tracker.note(kind, model: model)
        let discard = kind == .weightsUnreadable
        switch decide(kind, prior) {
        case .retryable(let why):
            return LocalSummaryResolution(error: RetryableDependencyError(why), discardWeights: discard, permanent: false)
        case .fail(let why):
            return LocalSummaryResolution(error: LocalSummaryError(why), discardWeights: discard, permanent: discard)
        }
    }
}

/// A permanent local-summary failure (the message is user-facing).
public struct LocalSummaryError: Error, Equatable, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Consecutive failure count per model and kind, so "retry once, then fail"
/// survives across pipeline attempts. A success resets the model's counts.
public final class LocalSummaryFailureTracker: @unchecked Sendable {
    public static let shared = LocalSummaryFailureTracker()
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    public init() {}

    /// Records one failure and returns how many of this kind came BEFORE it.
    public func note(_ kind: LocalSummaryFailureKind, model: String) -> Int {
        lock.withLock {
            let key = "\(model)|\(kind.key)"
            let prior = counts[key] ?? 0
            counts[key] = prior + 1
            return prior
        }
    }

    public func noteSuccess(model: String) {
        lock.withLock { counts = counts.filter { !$0.key.hasPrefix("\(model)|") } }
    }
}
