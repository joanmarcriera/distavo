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
    public static func summarise(
        transcript: String, noteOwner: String, userSpeaker: String,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        // Fall back to the handler set by the app when no per-call one is given.
        let report: @Sendable (String) -> Void = onProgress ?? { handlerBox.report($0) }
        if let reason = unavailableReason() { throw reason }

        #if canImport(FoundationModels)
        guard #available(macOS 26, *) else { throw EmbeddedSummariserError.unsupportedOS }

        let model = SystemLanguageModel.default
        let contextSize = model.contextSize

        let finalBudget = EmbeddedSummaryBudget.final(
            contextSize: contextSize, noteOwner: noteOwner, userSpeaker: userSpeaker)
        let mapBudget = EmbeddedSummaryBudget.map(contextSize: contextSize)

        let plan = EmbeddedSummaryPlanner.plan(
            transcript: transcript, contextSize: contextSize,
            noteOwner: noteOwner, userSpeaker: userSpeaker)

        switch plan {
        case .single:
            report("Summarising on this Mac…")
            let prompt = Prompt.build(
                transcript: transcript, noteOwner: noteOwner, userSpeaker: userSpeaker)
            return try await generate(prompt, maxOutputTokens: finalBudget.reservedForOutput)

        case .mapReduce(let chunks):
            guard !chunks.isEmpty else { throw EmbeddedSummariserError.emptyResult }
            var partials: [String] = []
            partials.reserveCapacity(chunks.count)
            for (i, chunk) in chunks.enumerated() {
                report("Summarising part \(i + 1) of \(chunks.count) on this Mac…")
                let text = try await generate(
                    EmbeddedSummaryPrompt.map(chunk: chunk, index: i + 1, total: chunks.count),
                    maxOutputTokens: mapBudget.reservedForOutput)
                partials.append(text)
            }
            report("Writing the note…")
            // The merged bullets stand in for the transcript in the normal prompt.
            // They are far shorter than the original, but a very long meeting can
            // still overflow, so fold them down until they fit.
            let merged = try await reduceToFit(
                partials: partials, contextSize: contextSize,
                noteOwner: noteOwner, userSpeaker: userSpeaker, onProgress: report)
            return try await generate(
                Prompt.build(transcript: merged, noteOwner: noteOwner, userSpeaker: userSpeaker),
                maxOutputTokens: finalBudget.reservedForOutput)
        }
        #else
        throw EmbeddedSummariserError.unsupportedOS
        #endif
    }

    #if canImport(FoundationModels)
    /// Collapse partial notes until they fit the final prompt's budget.
    ///
    /// A meeting long enough to produce more bullet notes than the window can
    /// hold gets another map pass over the notes themselves. Bounded to a few
    /// rounds so a pathological transcript cannot loop forever.
    @available(macOS 26, *)
    private static func reduceToFit(
        partials: [String], contextSize: Int, noteOwner: String, userSpeaker: String,
        onProgress: @Sendable (String) -> Void
    ) async throws -> String {
        let budget = EmbeddedSummaryBudget.final(
            contextSize: contextSize, noteOwner: noteOwner, userSpeaker: userSpeaker)
        var merged = EmbeddedSummaryPrompt.merge(partials: partials)

        for round in 1...3 {
            if EmbeddedSummaryTokens.estimate(merged) <= budget.transcriptTokens { return merged }
            onProgress("Condensing notes (pass \(round))…")
            let mapBudget = EmbeddedSummaryBudget.map(contextSize: contextSize)
            let chunks = EmbeddedSummaryPlanner.chunks(
                transcript: merged, budgetTokens: mapBudget.transcriptTokens)
            guard !chunks.isEmpty else { break }
            var condensed: [String] = []
            for (i, chunk) in chunks.enumerated() {
                condensed.append(try await generate(
                    EmbeddedSummaryPrompt.map(chunk: chunk, index: i + 1, total: chunks.count),
                    maxOutputTokens: mapBudget.reservedForOutput))
            }
            let folded = EmbeddedSummaryPrompt.merge(partials: condensed)
            // A single chunk still folds (the bullets get terser), but if a round
            // stops shrinking, further rounds are wasted model calls. Keep the
            // SMALLER of the two: adopting a folded result that grew would hand
            // the truncation below a longer string and discard more real content
            // than necessary.
            guard folded.count < merged.count else { break }
            merged = folded
        }

        // Still too long after bounded folding — truncate on a line boundary so
        // the final pass produces a note instead of throwing.
        let maxChars = Int(Double(budget.transcriptTokens) * EmbeddedSummaryTokens.charsPerToken)
        guard merged.count > maxChars else { return merged }
        let cut = String(merged.prefix(maxChars))
        return cut.contains("\n") ? String(cut[..<cut.lastIndex(of: "\n")!]) : cut
    }

    /// One generation call on a fresh session, with Foundation Models' errors
    /// mapped onto Distavo's own error type.
    ///
    /// `maxOutputTokens` is passed through to `maximumResponseTokens` so the
    /// answer cannot grow into the space the prompt already occupies — the
    /// commonest cause of `exceededContextWindowSize`.
    @available(macOS 26, *)
    private static func generate(_ prompt: String, maxOutputTokens: Int) async throws -> String {
        let model = SystemLanguageModel.default
        // Clamp the answer against the REAL token count of this prompt. The
        // character heuristic in DistavoCore is deliberately pessimistic but
        // still only an estimate; asking for more output than the window can
        // hold is what raises exceededContextWindowSize. Measuring here means a
        // heuristic miss costs a shorter answer, not a failed recording.
        var outputTokens = maxOutputTokens
        if #available(macOS 26.4, *), let measured = try? await model.tokenCount(for: Prompt(prompt)) {
            let available = model.contextSize - measured - EmbeddedSummaryBudget.defaultSafetyMargin
            guard available > 0 else {
                throw EmbeddedSummariserError.failed(
                    "a section of the recording was still too long after chunking "
                    + "(\(measured) tokens vs a \(model.contextSize)-token window)")
            }
            outputTokens = min(maxOutputTokens, available)
        }

        let session = LanguageModelSession(model: model)
        do {
            // Temperature matches the Ollama path's 0.1 — meeting notes should be
            // reproducible, not creative.
            let response = try await session.respond(
                to: prompt,
                options: GenerationOptions(temperature: 0.1,
                                           maximumResponseTokens: outputTokens))
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { throw EmbeddedSummariserError.emptyResult }
            return text
        } catch let error as EmbeddedSummariserError {
            throw error
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
    #endif
}
