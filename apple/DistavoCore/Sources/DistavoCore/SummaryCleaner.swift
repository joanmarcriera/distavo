import Foundation

/// Post-process safety net for model output that doesn't follow the prompt's
/// output contract (Vikunja #2203).
///
/// The facts-first prompt (`Prompt.factsFirstTemplate`) instructs the model to
/// "show your working" under "## Step 1" / "## Step 2" headings before writing
/// the actual note starting at "# Meeting notes". Some models (observed with
/// gemma4:26b) emit that working preamble verbatim in the response instead of
/// folding it into the note's own "## Speakers" / "## Facts ledger" sections —
/// the saved note then opens with "## Step 1: identify the speakers …" instead
/// of "# Meeting notes". The prompt itself was tightened to forbid this
/// (`Prompt.factsFirstTemplate`'s "Output ONLY the notes below…" line); this
/// is the belt-and-braces cleanup for when a model ignores that instruction
/// anyway.
public enum SummaryCleaner {

    /// If `text` contains a line starting with `"## Step "` before the first
    /// `"# Meeting notes"` line, drop everything before that line — but only
    /// when what follows still contains `"## Facts ledger"` or
    /// `"## Speakers"`. If the ledger/speakers content only exists in the
    /// discarded preamble (never repeated inside the note), the text is
    /// returned unchanged — we never silently throw away the only copy of
    /// the ledger — and `onLeakDetected` is called with a description of
    /// what was found, for the caller to log.
    public static func stripLeakedWorkingSteps(
        _ text: String, onLeakDetected: ((String) -> Void)? = nil
    ) -> String {
        let lines = text.components(separatedBy: "\n")
        guard let noteIndex = lines.firstIndex(where: { $0.hasPrefix("# Meeting notes") }) else {
            return text
        }
        let hasLeakedStepHeading = lines[..<noteIndex].contains {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("## Step ")
        }
        guard hasLeakedStepHeading else { return text }

        let body = lines[noteIndex...].joined(separator: "\n")
        guard body.contains("## Facts ledger") || body.contains("## Speakers") else {
            onLeakDetected?(
                "facts-first response leaked \"## Step\" working notes before \"# Meeting notes\", " +
                "but the ledger/speakers sections only exist in that discarded preamble — keeping the response unchanged.")
            return text
        }
        return body
    }
}
