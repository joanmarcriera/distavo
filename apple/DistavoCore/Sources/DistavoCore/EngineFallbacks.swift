import Foundation

// Two small policies found in the real-meeting log (Vikunja #5284, docs/findings-real-meetings-2026-10-25.md).
// Both are pure so they are tested through the `PipelineDeps` seam; the app target wires them in.

extension SummaryDriverError {
    /// A context window that cannot hold the instructions plus an answer is a condition of the model's
    /// current state (Apple's model reports a size of 0 while it is not ready, #1793), not of the recording:
    /// it DEFERS, like any absent dependency, instead of being failed for good (8 Oct log line).
    /// nil for every other driver error, which stay hard failures.
    public var deferral: RetryableDependencyError? {
        guard case .contextTooSmall = self else { return nil }
        return RetryableDependencyError(
            "The on-device summary model's context window is too small right now - will retry. "
            + "Switch summarisation to Ollama in Settings if this keeps happening.")
    }
}

/// An error that means "the engine ran and heard nothing" (as opposed to crashing).
public protocol EmptyTranscriptSignal: Error {
    var isEmptyTranscript: Bool { get }
}

/// Runs the primary engine and, when it produces no text, the fallback engine - once. Parakeet returned
/// "Built-in transcription produced no text" for two mic-only recordings on 14 Oct; WhisperKit can read them.
public enum TranscribeFallback {
    public static func run(
        primary: () async throws -> [String: Any],
        fallback: () async throws -> [String: Any]
    ) async throws -> (result: [String: Any], usedFallback: Bool) {
        do {
            let result = try await primary()
            let text = TranscriptCleaner.segments(from: result).map(\.text).joined(separator: " ")
            guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return (result, false) }
        } catch let signal as EmptyTranscriptSignal where signal.isEmptyTranscript {
            // fall through to the fallback engine
        }
        return (try await fallback(), true)
    }
}
