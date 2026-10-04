import Foundation

// Engine-agnostic summarisation driver (Vikunja #2198, slice S3).
//
// The plan -> map -> reduceToFit -> final flow used to live inside
// `EmbeddedSummariser` behind `#if canImport(FoundationModels)`, so none of it
// could be unit-tested. It now lives here, driving any `SummaryGenerator`:
// Apple's Foundation Models is one adapter (DistavoEmbedded), the MLX Gemma
// generator (S4) and a later macOS 27 `LanguageModel` adapter are others.
// DistavoCore stays dependency-free: only a protocol crosses the boundary.
//
// Parity contract: with the default request (classic style, no date, no
// language, no end-of-turn block) the prompts, their order and their
// `maxOutputTokens` are byte-for-byte what `EmbeddedSummariser` produced before
// this refactor (pinned by SummaryDriverTests).

/// One model behind the driver. Implementations hold no state between calls
/// beyond what they need (the menu-bar app keeps no model resident).
public protocol SummaryGenerator: Sendable {
    /// Distavo's usable window in tokens (input + output), which may be smaller
    /// than the model's own: for Gemma it is the catalogue's `contextCap`.
    var contextSize: Int { get }
    /// The model's real token count for `text`, or nil to rely on the
    /// character heuristic (`EmbeddedSummaryTokens`).
    func tokenCount(_ text: String) async -> Int?
    /// One generation on a fresh session. Throws the engine's own errors.
    func generate(_ prompt: String, maxOutputTokens: Int) async throws -> String
}

/// Failures the driver itself can diagnose. Engine errors from
/// `SummaryGenerator.generate` propagate untouched.
public enum SummaryDriverError: Error, Equatable {
    /// The window cannot hold the map instructions plus an answer.
    case contextTooSmall
    /// A generation (or the plan) produced no text.
    case emptyResult
    /// A prompt measured with the real tokenizer leaves no room for an answer
    /// (`measured` tokens against a `contextSize`-token window).
    case promptTooLong(measured: Int, contextSize: Int)
}

/// Everything the driver needs besides the generator.
public struct SummaryRequest: Sendable {
    public var transcript: String
    public var noteOwner: String
    public var userSpeaker: String
    public var participants: String?
    public var style: Prompt.Style
    public var meetingDate: Date?
    public var noteLanguage: String?
    /// Appended to the FINAL prompt only (after the transcript), where long-
    /// context models weigh it most — see `EndOfTurnBlock`. nil = nothing.
    public var endOfTurnBlock: String?

    public init(transcript: String, noteOwner: String, userSpeaker: String,
                participants: String? = nil, style: Prompt.Style = .classic,
                meetingDate: Date? = nil, noteLanguage: String? = nil,
                endOfTurnBlock: String? = nil) {
        self.transcript = transcript; self.noteOwner = noteOwner
        self.userSpeaker = userSpeaker; self.participants = participants
        self.style = style; self.meetingDate = meetingDate
        self.noteLanguage = noteLanguage; self.endOfTurnBlock = endOfTurnBlock
    }
}

public enum SummaryDriver {

    /// Bounded number of "condense the notes again" rounds in `reduceToFit`.
    public static let maxFoldRounds = 3

    /// Produce meeting notes from a cleaned transcript with `generator`.
    ///
    /// A transcript that fits is summarised in one pass with the normal prompt.
    /// A longer one is map-reduced: each chunk becomes compact bullets, which
    /// are then fed through the *same* normal prompt, so the note keeps the
    /// shape `SummaryValidator` expects either way. `participants` and the
    /// end-of-turn block reach the final prompt only.
    public static func run(
        _ request: SummaryRequest, generator: some SummaryGenerator,
        onProgress: @Sendable (String) -> Void = { _ in }
    ) async throws -> String {
        let contextSize = generator.contextSize
        let finalBudget = EmbeddedSummaryBudget.final(
            contextSize: contextSize, noteOwner: request.noteOwner,
            userSpeaker: request.userSpeaker, style: request.style)
        let mapBudget = EmbeddedSummaryBudget.map(contextSize: contextSize)

        let plan = EmbeddedSummaryPlanner.plan(
            transcript: request.transcript, contextSize: contextSize,
            noteOwner: request.noteOwner, userSpeaker: request.userSpeaker,
            style: request.style)

        switch plan {
        case .single:
            onProgress("Summarising on this Mac…")
            return try await generate(
                finalPrompt(request, transcript: request.transcript),
                maxOutputTokens: finalBudget.reservedForOutput, generator)

        case .contextTooSmall:
            throw SummaryDriverError.contextTooSmall

        case .mapReduce(let chunks):
            guard !chunks.isEmpty else { throw SummaryDriverError.emptyResult }
            var partials: [String] = []
            partials.reserveCapacity(chunks.count)
            for (i, chunk) in chunks.enumerated() {
                onProgress("Summarising part \(i + 1) of \(chunks.count) on this Mac…")
                partials.append(try await generate(
                    EmbeddedSummaryPrompt.map(chunk: chunk, index: i + 1, total: chunks.count),
                    maxOutputTokens: mapBudget.reservedForOutput, generator))
            }
            onProgress("Writing the note…")
            // The merged bullets stand in for the transcript in the normal
            // prompt. They are far shorter than the original, but a very long
            // meeting can still overflow, so fold them down until they fit.
            let merged = try await reduceToFit(
                partials: partials, request: request, generator: generator,
                onProgress: onProgress)
            return try await generate(
                finalPrompt(request, transcript: merged),
                maxOutputTokens: finalBudget.reservedForOutput, generator)
        }
    }

    /// The final prompt for `transcript` (the real one, or merged notes).
    static func finalPrompt(_ request: SummaryRequest, transcript: String) -> String {
        let prompt = Prompt.build(
            transcript: transcript, noteOwner: request.noteOwner,
            userSpeaker: request.userSpeaker, participants: request.participants,
            style: request.style, meetingDate: request.meetingDate,
            noteLanguage: request.noteLanguage)
        guard let block = request.endOfTurnBlock?.trimmingCharacters(in: .whitespacesAndNewlines),
              !block.isEmpty else { return prompt }
        return prompt + "\n" + block + "\n"
    }

    /// Collapse partial notes until they fit the final prompt's budget.
    ///
    /// A meeting long enough to produce more bullet notes than the window can
    /// hold gets another map pass over the notes themselves. Bounded to
    /// `maxFoldRounds` so a pathological transcript cannot loop forever, and a
    /// round that stops shrinking ends the folding (further rounds would only
    /// waste model calls); the result is then truncated on a line boundary so
    /// the final pass still produces a note instead of throwing.
    static func reduceToFit(
        partials: [String], request: SummaryRequest, generator: some SummaryGenerator,
        onProgress: @Sendable (String) -> Void
    ) async throws -> String {
        let contextSize = generator.contextSize
        let budget = EmbeddedSummaryBudget.final(
            contextSize: contextSize, noteOwner: request.noteOwner,
            userSpeaker: request.userSpeaker, style: request.style)
        let mapBudget = EmbeddedSummaryBudget.map(contextSize: contextSize)
        var merged = EmbeddedSummaryPrompt.merge(partials: partials)

        for round in 1...maxFoldRounds {
            if EmbeddedSummaryTokens.estimate(merged) <= budget.transcriptTokens { return merged }
            onProgress("Condensing notes (pass \(round))…")
            let chunks = EmbeddedSummaryPlanner.chunks(
                transcript: merged, budgetTokens: mapBudget.transcriptTokens)
            guard !chunks.isEmpty else { break }
            var condensed: [String] = []
            for (i, chunk) in chunks.enumerated() {
                condensed.append(try await generate(
                    EmbeddedSummaryPrompt.map(chunk: chunk, index: i + 1, total: chunks.count),
                    maxOutputTokens: mapBudget.reservedForOutput, generator))
            }
            let folded = EmbeddedSummaryPrompt.merge(partials: condensed)
            // Keep the SMALLER of the two: adopting a folded result that grew
            // would hand the truncation below a longer string and discard more
            // real content than necessary.
            guard folded.count < merged.count else { break }
            merged = folded
        }

        let maxChars = Int(Double(budget.transcriptTokens) * EmbeddedSummaryTokens.charsPerToken)
        guard merged.count > maxChars else { return merged }
        let cut = String(merged.prefix(maxChars))
        return cut.contains("\n") ? String(cut[..<cut.lastIndex(of: "\n")!]) : cut
    }

    /// One call, with the answer clamped against the REAL token count of the
    /// prompt when the generator can measure it. The character heuristic is
    /// deliberately pessimistic but still an estimate; asking for more output
    /// than the window can hold is what makes a model raise a context error, so
    /// a heuristic miss should cost a shorter answer, not a failed recording.
    static func generate(
        _ prompt: String, maxOutputTokens: Int, _ generator: some SummaryGenerator
    ) async throws -> String {
        var outputTokens = maxOutputTokens
        if let measured = await generator.tokenCount(prompt) {
            let available = generator.contextSize - measured - EmbeddedSummaryBudget.defaultSafetyMargin
            guard available > 0 else {
                throw SummaryDriverError.promptTooLong(
                    measured: measured, contextSize: generator.contextSize)
            }
            outputTokens = min(maxOutputTokens, available)
        }
        let text = try await generator.generate(prompt, maxOutputTokens: outputTokens)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { throw SummaryDriverError.emptyResult }
        return text
    }
}
