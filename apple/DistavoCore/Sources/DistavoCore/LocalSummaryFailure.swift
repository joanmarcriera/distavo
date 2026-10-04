import Foundation

// Failure taxonomy for the local (MLX Gemma) summary engine (Vikunja #2198, S4).
// Pure functions of an error message, so the defer-or-fail decision is unit-
// tested without a GPU. Mirrors the rule already used for Apple's model and
// Ollama: a transient condition defers (RetryableDependencyError), a condition
// that will not fix itself fails once with guidance.
//
// Caveat recorded in the brainstorm (open item 9): a RetryableDependencyError
// thrown during summarise makes the next attempt re-transcribe the recording,
// so generate-time deferral is expensive — hence only ONE OOM is retried.

public enum LocalSummaryFailureKind: Equatable, Sendable {
    /// Metal/MLX could not allocate (another GPU app busy, memory pressure).
    case outOfMemory
    /// The stream looped again after the one temperature-bumped retry.
    case repetitionCollapse
    /// Weights/tokenizer files missing or corrupt on disk.
    case weightsUnreadable
    /// The model produced no text.
    case emptyOutput
    case other(String)
}

public enum LocalSummaryFailureDecision: Equatable, Sendable {
    /// Defer: the recording stays pending and is retried with backoff.
    case retryable(String)
    /// Fail once, with a message that tells the user what to do.
    case fail(String)
}

public enum LocalSummaryFailurePolicy {

    /// Map an engine error message onto a kind. Matching is case-insensitive
    /// and deliberately broad: MLX surfaces Metal errors as free text.
    public static func classify(message: String) -> LocalSummaryFailureKind {
        let m = message.lowercased()
        let oom = ["out of memory", "outofmemory", "insufficient memory", "failed to allocate",
                   "attempting to allocate", "kiogpucommandbuffercallbackerroroutofmemory"]
        if oom.contains(where: m.contains) { return .outOfMemory }
        let unreadable = ["no safetensors", "unable to load weights", "is corrupt", "missing tokenizer",
                          "missing config", "could not load model", "no such file"]
        if unreadable.contains(where: m.contains) { return .weightsUnreadable }
        return .other(message)
    }

    /// `priorOutOfMemory` = how many OOMs in a row this model has already hit
    /// (0 on the first).
    public static func decide(_ kind: LocalSummaryFailureKind, priorOutOfMemory: Int) -> LocalSummaryFailureDecision {
        switch kind {
        case .outOfMemory:
            if priorOutOfMemory == 0 {
                return .retryable("The Mac ran short of memory while summarising — Distavo will try again shortly.")
            }
            return .fail("The local summary model ran out of memory twice in a row. Close other heavy apps, "
                         + "or switch summaries to Apple Intelligence or Ollama in Settings.")
        case .weightsUnreadable:
            return .retryable("The local summary model's files are unreadable — Distavo will download them again.")
        case .repetitionCollapse:
            return .fail("The local summary model got stuck repeating itself, even after a retry. "
                         + "Try again later, or use Ollama in Settings.")
        case .emptyOutput:
            return .fail("The local summary model produced no text.")
        case .other(let message):
            return .fail("Local summarisation failed: \(message)")
        }
    }

    /// The user-facing message of a permanent decision for `kind`.
    public static func decideMessage(for kind: LocalSummaryFailureKind) -> String {
        switch decide(kind, priorOutOfMemory: 1) {
        case .retryable(let m), .fail(let m): return m
        }
    }

    /// Classify + decide + record, returning the error the engine should throw:
    /// a `RetryableDependencyError` for a deferral, otherwise a plain error.
    public static func resolve(_ error: Error, model: String, tracker: LocalSummaryFailureTracker) -> Error {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let kind = classify(message: message)
        let prior = kind == .outOfMemory ? tracker.noteOutOfMemory(model: model) : 0
        switch decide(kind, priorOutOfMemory: prior) {
        case .retryable(let why): return RetryableDependencyError(why)
        case .fail(let why): return LocalSummaryError(why)
        }
    }
}

/// A permanent local-summary failure (the message is user-facing).
public struct LocalSummaryError: Error, Equatable, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Consecutive out-of-memory count per model, so "retry once, then fail"
/// survives across pipeline attempts. A success resets it.
public final class LocalSummaryFailureTracker: @unchecked Sendable {
    public static let shared = LocalSummaryFailureTracker()
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    public init() {}

    /// Records an OOM and returns how many came BEFORE it.
    public func noteOutOfMemory(model: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        let prior = counts[model] ?? 0
        counts[model] = prior + 1
        return prior
    }

    public func noteSuccess(model: String) {
        lock.lock(); counts[model] = nil; lock.unlock()
    }
}
