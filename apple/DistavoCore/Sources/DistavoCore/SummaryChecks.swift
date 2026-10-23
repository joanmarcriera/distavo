import Foundation

/// Checks run on a model's summary before it becomes a note (1.19). Shared by
/// `Pipeline.processOne` and `Pipeline.regenerate`, which used to carry
/// parallel copies of their post-processing: anything added here reaches both.
///
/// `apply` gets the summary after the leaked-working-steps strip, title/tag
/// extraction and scratchpad highlights, and BEFORE Key moments and the footer
/// are appended. It may rewrite the text (e.g. drop unsupported facts-ledger
/// rows), add lines for the note's summary footer, and report failures in the
/// same wording style as `SummaryValidator` (a failure rejects the summary).
public struct SummaryCheckOutcome: Equatable, Sendable {
    /// The summary text to keep.
    public var text: String
    /// Short sentences for the summary footer line (see `NoteFooterLines`), in order.
    public var notes: [String]
    /// Validator-style failure strings; empty = pass.
    public var failures: [String]

    public init(text: String, notes: [String] = [], failures: [String] = []) {
        self.text = text; self.notes = notes; self.failures = failures
    }
}

public enum SummaryChecks {
    /// - Parameters:
    ///   - summary: the cleaned model output (no Key moments, no footer).
    ///   - transcript: the clean transcript the model was given.
    ///   - context: the note context the prompt was built from.
    public static func apply(summary: String, transcript: String, context: NoteContext) -> SummaryCheckOutcome {
        // Speaker labels respelled / listed on lines of their own by small models (#1793); every style.
        // Prompt scaffolding copied into the note (Step headings, instruction sentences) goes first (#4010).
        let relabelled = SpeakerLabelNormaliser.normalise(ScaffoldingScrubber.scrub(summary), transcript: transcript)
        // Facts-ledger rows the transcript does not support are dropped or flagged (#3581).
        guard context.promptStyle == .factsFirst else {
            return SummaryCheckOutcome(text: relabelled, notes: context.summaryNotes)
        }
        let ledger = LedgerVerifier.verify(relabelled, transcript: transcript)
        return SummaryCheckOutcome(text: ledger.text, notes: context.summaryNotes + LedgerVerifier.notes(for: ledger))
    }
}

/// The note's footer is two parts (1.19):
///
/// 1. the provenance line, "_Transcribed on this Mac with …_" (`NoteProvenance`),
///    which describes the transcription and is carried over by Regenerate;
/// 2. an optional summary line, "_Summary: …_", which describes THIS summary
///    (ledger rows removed, note language, template chosen) and is rebuilt by
///    every summarise, never carried over.
///
/// With neither part the footer is "" and the note is byte-identical to before.
public enum NoteFooterLines {
    static let summaryOpening = "_Summary: "

    /// `provenance` is a `NoteProvenance.footer` block or "".
    public static func footer(provenance: String, summaryNotes: [String]) -> String {
        let notes = summaryNotes.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !notes.isEmpty else { return provenance }
        let line = summaryOpening + notes.map(sentence).joined(separator: " ") + "_"
        return provenance.isEmpty ? "\n\n---\n" + line : provenance + "\n\n" + line
    }

    /// The provenance part of a footer taken from an existing note: drops a
    /// previous summary line so Regenerate does not carry a stale one over.
    public static func provenanceOnly(_ footer: String) -> String {
        guard let range = footer.range(of: "\n\n" + summaryOpening) else { return footer }
        return String(footer[..<range.lowerBound])
    }

    private static func sentence(_ s: String) -> String {
        guard let last = s.last, !".!?".contains(last) else { return s }
        return s + "."
    }
}
