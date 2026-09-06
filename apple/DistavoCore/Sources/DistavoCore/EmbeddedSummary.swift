import Foundation

// Dependency-free support for on-device summarisation (Vikunja #336). The
// engine itself lives in DistavoEmbedded (it needs FoundationModels); this file
// holds the parts that are pure functions of text and a token budget, so they
// can be unit-tested without Apple Intelligence, a model, or even macOS 26:
// token estimation, chunk planning, and the map/reduce prompts.
//
// Why any of this is needed: Apple's on-device model has a 4096-token context
// covering input AND output combined, while Distavo's existing prompt template
// alone measures 779 tokens and a one-hour meeting transcript is ~13 000. See
// docs/embedded-summarisation-decision.md for the measurements.

/// Token estimation without a tokenizer.
///
/// `SystemLanguageModel.tokenCount(for:)` is exact but is async, macOS 26.4+,
/// and lives in FoundationModels — none of which belongs in DistavoCore. A
/// character heuristic is enough here because it only has to pick chunk
/// boundaries, and the engine re-checks the real count before generating.
public enum EmbeddedSummaryTokens {
    /// **Calibrated on transcripts, not prose.** Apple's tokenizer measures
    /// 4.10 chars/token on Distavo's prompt template (clean English), but only
    /// **3.46** on a real 97-minute meeting transcript, and **2.22** on a single
    /// `SPEAKER_00: ...` line — speaker labels, disfluencies, names and numbers
    /// all tokenize far worse than prose.
    ///
    /// A 4.0 constant under-counted a real transcript by 1263 tokens (15%) and
    /// overflowed the context window in the field. 3.0 is below the measured
    /// transcript density on purpose: over-estimating only shrinks chunks, while
    /// under-estimating fails the whole recording.
    public static let charsPerToken = 3.0

    public static func estimate(_ text: String) -> Int {
        Int(ceil(Double(text.count) / charsPerToken))
    }
}

/// How much of the context window is left for transcript text, once the
/// instructions and the space the answer needs are accounted for.
public struct EmbeddedSummaryBudget: Equatable {
    /// The model's full context window (input + output together).
    public let contextSize: Int
    /// Tokens held back for the model's own answer.
    public let reservedForOutput: Int
    /// Tokens the instruction text costs.
    public let instructionTokens: Int
    /// Slack left unallocated. Spending the window down to the last token fails
    /// even when the arithmetic is exact: the model raises
    /// `exceededContextWindowSize` when it cannot finish a response *within* the
    /// window, so the boundary itself is not usable.
    public let safetyMargin: Int

    public static let defaultSafetyMargin = 128

    public init(contextSize: Int, reservedForOutput: Int, instructionTokens: Int,
                safetyMargin: Int = defaultSafetyMargin) {
        self.contextSize = contextSize
        self.reservedForOutput = reservedForOutput
        self.instructionTokens = instructionTokens
        self.safetyMargin = safetyMargin
    }

    /// Tokens of transcript that fit. Never negative — a budget that cannot fit
    /// its own instructions yields 0, which the planner treats as "unusable".
    public var transcriptTokens: Int {
        max(0, contextSize - reservedForOutput - instructionTokens - safetyMargin)
    }

    /// Budget for a **map** step: the compact per-chunk prompt, whose answer is
    /// a short bullet list rather than the full note.
    public static func map(contextSize: Int) -> EmbeddedSummaryBudget {
        EmbeddedSummaryBudget(
            contextSize: contextSize,
            reservedForOutput: 700,
            instructionTokens: EmbeddedSummaryTokens.estimate(EmbeddedSummaryPrompt.mapInstructions))
    }

    /// Budget for the **final** step: Distavo's full 16-section prompt, whose
    /// answer is a complete note with two tables and an email.
    ///
    /// `reservedForOutput` is 1800 — the smoke test produced ~700 tokens for a
    /// trivial transcript, and a real meeting fills the tables.
    public static func final(contextSize: Int, noteOwner: String, userSpeaker: String)
        -> EmbeddedSummaryBudget {
        let instructions = Prompt.build(transcript: "", noteOwner: noteOwner, userSpeaker: userSpeaker)
        return EmbeddedSummaryBudget(
            contextSize: contextSize,
            reservedForOutput: 1800,
            instructionTokens: EmbeddedSummaryTokens.estimate(instructions))
    }
}

/// What the engine should do with a given transcript.
public enum EmbeddedSummaryPlan: Equatable {
    /// The transcript fits — summarise it in one pass with the normal prompt.
    case single
    /// Too long — summarise each chunk, then summarise the summaries.
    case mapReduce(chunks: [String])
    /// The context window cannot even hold the map instructions plus the space
    /// reserved for an answer, so no chunk of ANY size would fit. Distinct from
    /// `.mapReduce(chunks: [])` so the surfaced error can blame the window
    /// rather than the model: "produced no text" sends the user to check Apple
    /// Intelligence when the real fault is a context size that is too small.
    case contextTooSmall
}

public enum EmbeddedSummaryPlanner {

    /// Split a cleaned transcript into chunks that each fit `budgetTokens`.
    ///
    /// Splits on line boundaries, because `TranscriptCleaner` emits one speaker
    /// turn per line — keeping turns intact keeps attribution correct. A single
    /// turn longer than the budget (a monologue) is hard-split on whitespace.
    public static func chunks(transcript: String, budgetTokens: Int) -> [String] {
        guard budgetTokens > 0 else { return [] }
        let lines = transcript.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        var chunks: [String] = []
        var current: [String] = []
        var currentTokens = 0

        func flush() {
            let joined = current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { chunks.append(joined) }
            current = []
            currentTokens = 0
        }

        for line in lines {
            let lineTokens = EmbeddedSummaryTokens.estimate(line)

            // A single line that cannot ever fit: flush, then hard-split it.
            if lineTokens > budgetTokens {
                flush()
                for piece in splitLongLine(line, budgetTokens: budgetTokens) {
                    chunks.append(piece)
                }
                continue
            }

            // +1 for the newline that will rejoin this line to the previous one.
            let cost = current.isEmpty ? lineTokens : lineTokens + 1
            if currentTokens + cost > budgetTokens { flush() }
            current.append(line)
            currentTokens += current.count == 1 ? lineTokens : cost
        }
        flush()
        return chunks
    }

    /// Break one over-long line on whitespace so no chunk exceeds the budget.
    /// Falls back to a character split for text with no spaces at all.
    static func splitLongLine(_ line: String, budgetTokens: Int) -> [String] {
        let maxChars = max(1, Int(Double(budgetTokens) * EmbeddedSummaryTokens.charsPerToken))
        var pieces: [String] = []
        var current = ""

        for word in line.split(separator: " ", omittingEmptySubsequences: false).map(String.init) {
            let candidate = current.isEmpty ? word : current + " " + word
            if candidate.count <= maxChars {
                current = candidate
                continue
            }
            if !current.isEmpty { pieces.append(current); current = "" }
            // The word alone still overflows — cut it into fixed-size pieces.
            if word.count > maxChars {
                var rest = Substring(word)
                while rest.count > maxChars {
                    pieces.append(String(rest.prefix(maxChars)))
                    rest = rest.dropFirst(maxChars)
                }
                current = String(rest)
            } else {
                current = word
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Decide between one pass and map-reduce for this transcript.
    public static func plan(
        transcript: String, contextSize: Int, noteOwner: String, userSpeaker: String
    ) -> EmbeddedSummaryPlan {
        let finalBudget = EmbeddedSummaryBudget.final(
            contextSize: contextSize, noteOwner: noteOwner, userSpeaker: userSpeaker)
        if EmbeddedSummaryTokens.estimate(transcript) <= finalBudget.transcriptTokens {
            return .single
        }
        let mapBudget = EmbeddedSummaryBudget.map(contextSize: contextSize)
        guard mapBudget.transcriptTokens > 0 else { return .contextTooSmall }
        return .mapReduce(
            chunks: chunks(transcript: transcript, budgetTokens: mapBudget.transcriptTokens))
    }
}

/// Prompts for the map-reduce path. The **reduce** step deliberately reuses
/// `Prompt.build` with the merged partial notes standing in for the transcript,
/// so the final note keeps the exact format `SummaryValidator` and the rest of
/// the app already expect.
public enum EmbeddedSummaryPrompt {

    /// Instructions for one chunk. Kept short on purpose — every token here is
    /// a token of transcript that no longer fits.
    public static let mapInstructions = """
    You are reading ONE PART of a longer meeting transcript.

    Extract only what this part actually contains, as short bullets under these headings:

    Key points:
    Decisions:
    Actions (who, what, when):
    Notable quotes (short, with speaker label):
    Open questions:

    Rules:
    - Do not invent facts. If a heading has nothing, write "none".
    - Keep speaker labels exactly as written (SPEAKER_00 etc.).
    - Do not write an introduction, a conclusion, or a summary of the whole meeting.
    - Be brief. Use British English.

    Part {index} of {total}:

    {chunk}

    """

    public static func map(chunk: String, index: Int, total: Int) -> String {
        mapInstructions
            .replacingOccurrences(of: "{index}", with: String(index))
            .replacingOccurrences(of: "{total}", with: String(total))
            .replacingOccurrences(of: "{chunk}", with: chunk)
    }

    /// Merge the per-chunk bullet notes into one pseudo-transcript for the final
    /// pass, labelled so the model knows it is reading notes, not speech.
    public static func merge(partials: [String]) -> String {
        partials.enumerated()
            .map { "--- Notes from part \($0.offset + 1) of \(partials.count) ---\n\($0.element)" }
            .joined(separator: "\n\n")
    }
}
