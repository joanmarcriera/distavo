import Foundation
import DistavoCore

#if canImport(FoundationModels)
import FoundationModels
#endif

// On-device summarisation via Apple's Foundation Models (Vikunja #336).
// Rationale, measurements and rejected alternatives: docs/embedded-summarisation-decision.md.
//
// Lives in DistavoEmbedded, not DistavoCore, for the same reason as the
// transcriber: DistavoCore must stay dependency-free so `swift test` runs fast
// and headless. The planning/budgeting logic this file drives is in
// DistavoCore's EmbeddedSummary.swift and is unit-tested there.
//
// `canImport` guards the whole framework so the package still builds against an
// SDK without FoundationModels; `@available(macOS 26, *)` guards the runtime,
// since Distavo's deployment target is macOS 14.

public enum EmbeddedSummariserError: LocalizedError, Equatable {
    case unsupportedOS
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    case emptyResult
    case contextTooSmall
    case refused(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedOS:
            return "On-device summarisation needs macOS 26 or later — switch "
                + "summarisation back to Ollama in Settings."
        case .deviceNotEligible:
            return "This Mac doesn't support Apple Intelligence, which on-device "
                + "summarisation requires — use Ollama in Settings instead."
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence is turned off. Enable it in System Settings "
                + "to summarise on this Mac, or use Ollama in Settings."
        case .modelNotReady:
            return "Apple Intelligence is still downloading its model. Try again "
                + "shortly, or use Ollama in Settings."
        case .emptyResult:
            return "On-device summarisation produced no text."
        case .contextTooSmall:
            return "The on-device model's context window is too small to summarise "
                + "anything — it cannot hold the instructions and an answer at once. "
                + "Use Ollama in Settings instead."
        case .refused(let why):
            return "The on-device model declined to summarise this recording (\(why)). "
                + "Ollama has no such content filter — switch to it in Settings."
        case .failed(let why):
            return "On-device summarisation failed: \(why)"
        }
    }
}

/// Summarises a cleaned transcript entirely on this Mac.
///
/// Sessions are created per call and dropped afterwards, mirroring
/// `EmbeddedTranscriber`'s per-call engine lifetime: the menu-bar app holds no
/// model state between meetings.
public enum EmbeddedSummariser {

    /// Progress reporting, mirroring `EmbeddedTranscriber.setProgressHandler`
    /// so `WatcherController` can surface map-reduce passes in the menu status
    /// and activity log. This type is stateless (an enum), so the handler is
    /// held in a lock-guarded box rather than actor state.
    private final class HandlerBox: @unchecked Sendable {
        private let lock = NSLock()
        private var handler: (@Sendable (String) -> Void)?
        func set(_ h: (@Sendable (String) -> Void)?) { lock.lock(); handler = h; lock.unlock() }
        func report(_ message: String) {
            lock.lock(); let h = handler; lock.unlock()
            h?(message)
        }
    }
    private static let handlerBox = HandlerBox()

    public static func setProgressHandler(_ handler: (@Sendable (String) -> Void)?) {
        handlerBox.set(handler)
    }

    /// Whether this Mac can summarise on-device right now, and if not, why.
    /// Returns nil when it can.
    public static func unavailableReason() -> EmbeddedSummariserError? {
        #if canImport(FoundationModels)
        guard #available(macOS 26, *) else { return .unsupportedOS }
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return .deviceNotEligible
            case .appleIntelligenceNotEnabled: return .appleIntelligenceNotEnabled
            case .modelNotReady: return .modelNotReady
            @unknown default: return .modelNotReady
            }
        }
        #else
        return .unsupportedOS
        #endif
    }

    public static var isAvailable: Bool { unavailableReason() == nil }

    /// Produce meeting notes from a cleaned transcript.
    ///
    /// Short transcripts go through Distavo's normal prompt in one pass. Longer
    /// ones are map-reduced: each chunk is summarised into compact bullets, then
    /// those bullets are fed through the *same* normal prompt, so the final note
    /// keeps the format `SummaryValidator` expects either way.
    /// `participants` is the owner's post-recording description of who was in
    /// the meeting (Vikunja #2182); it goes into the final prompt only — the
    /// map step summarises chunks without it.
    public static func summarise(
        transcript: String, noteOwner: String, userSpeaker: String,
        participants: String? = nil,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {

        // Fall back to the handler set by the app when no per-call one is given.
        let report: @Sendable (String) -> Void = onProgress ?? { handlerBox.report($0) }
        if let reason = unavailableReason() { throw reason }

        #if canImport(FoundationModels)
        guard #available(macOS 26, *) else { throw EmbeddedSummariserError.unsupportedOS }

        // The plan/map/reduce/final flow is engine-agnostic and lives in
        // DistavoCore's `SummaryDriver` (Vikunja #2198 S3); this type is the
        // Foundation Models adapter. Always the classic prompt on-device: the
        // 4096-token window cannot afford facts-first (Vikunja #2063).
        let request = SummaryRequest(
            transcript: transcript, noteOwner: noteOwner, userSpeaker: userSpeaker,
            participants: participants)
        do {
            return try await SummaryDriver.run(
                request, generator: FoundationModelsGenerator(), onProgress: report)
        } catch let error as SummaryDriverError {
            switch error {
            case .contextTooSmall:
                throw EmbeddedSummariserError.contextTooSmall
            case .emptyResult:
                throw EmbeddedSummariserError.emptyResult
            case .outputBudgetTooSmall(let available, let wanted):
                throw EmbeddedSummariserError.failed(
                    "a section of the recording left room for only \(available) of the "
                    + "\(wanted) tokens the note needs")
            case .promptTooLong(let measured, let contextSize):
                throw EmbeddedSummariserError.failed(
                    "a section of the recording was still too long after chunking "
                    + "(\(measured) tokens vs a \(contextSize)-token window)")
            }
        }
        #else
        throw EmbeddedSummariserError.unsupportedOS
        #endif
    }

    #if canImport(FoundationModels)
    /// Apple's on-device model as a `SummaryGenerator`: a fresh session per
    /// call, Foundation Models' errors mapped onto Distavo's own error type.
    @available(macOS 26, *)
    private struct FoundationModelsGenerator: SummaryGenerator {
        let contextSize: Int = SystemLanguageModel.default.contextSize

        /// The exact count (macOS 26.4+); nil on older systems, where the
        /// driver falls back to its character heuristic.
        func tokenCount(_ text: String) async -> Int? {
            guard #available(macOS 26.4, *) else { return nil }
            return try? await SystemLanguageModel.default.tokenCount(for: FoundationModels.Prompt(text))
        }

        /// `maxOutputTokens` reaches `maximumResponseTokens` so the answer cannot
        /// grow into the space the prompt already occupies — the commonest cause
        /// of `exceededContextWindowSize`. The driver has already clamped it
        /// against the measured prompt size.
        func generate(_ prompt: String, maxOutputTokens: Int) async throws -> String {
            let session = LanguageModelSession(model: SystemLanguageModel.default)
            do {
                // Temperature matches the Ollama path's 0.1 — meeting notes should be
                // reproducible, not creative.
                let response = try await session.respond(
                    to: prompt,
                    options: GenerationOptions(temperature: 0.1,
                                               maximumResponseTokens: maxOutputTokens))
                return response.content
            } catch let error as LanguageModelSession.GenerationError {
                switch error {
                case .exceededContextWindowSize:
                    // The planner budgets against an estimate; a miss should read as a
                    // size problem, not a mystery.
                    throw EmbeddedSummariserError.failed(
                        "the recording was too long for the on-device model's context window")
                case .guardrailViolation:
                    throw EmbeddedSummariserError.refused("content guardrail")
                case .refusal:
                    // Refusal.explanation is itself an async model call that can
                    // throw; not worth a second round-trip on a failed note.
                    throw EmbeddedSummariserError.refused("model refusal")
                case .unsupportedLanguageOrLocale:
                    throw EmbeddedSummariserError.failed(
                        "the on-device model doesn't support this recording's language")
                case .assetsUnavailable:
                    throw EmbeddedSummariserError.modelNotReady
                default:
                    throw EmbeddedSummariserError.failed(
                        error.errorDescription ?? "\(error)")
                }
            } catch {
                throw EmbeddedSummariserError.failed(error.localizedDescription)
            }
        }
    }
    #endif
}
