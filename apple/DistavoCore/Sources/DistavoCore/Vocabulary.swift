import Foundation

// Custom vocabulary and replacement dictionary (Vikunja #2939).
//
// Two user-supplied lists, both empty by default (an empty list changes nothing
// anywhere, byte for byte):
//   * `transcribe.vocabulary`   - names/jargon. Fed to the transcriber as a
//     prompt (WhisperX `initial_prompt`, WhisperKit `promptTokens`) and to the
//     summary prompt ("spell these exactly").
//   * `transcribe.replacements` - an ordered find/replace map applied to the
//     cleaned transcript before summarising, so transcript and note both carry
//     the corrected spelling.
//
// Pure and dependency-free so it is unit-tested headlessly; the engines only
// receive the resulting strings through the existing config seam.

/// One find/replace rule. `from` matches case-insensitively as whole words.
public struct ReplacementRule: Codable, Equatable, Sendable {
    public var from: String
    public var to: String

    public init(from: String, to: String) { self.from = from; self.to = to }
}

public enum Vocabulary {

    /// Whisper's prompt window is 224 tokens (half the 448 context). Terms are
    /// short and often rare words (many sub-word tokens), so budget ~2.5
    /// characters per token: 500 characters stays safely under 224 tokens.
    /// The built-in engine then re-checks with the real tokenizer
    /// (`transcriberPrompt(_:maxTokens:tokenCount:)`), dropping trailing terms,
    /// because WhisperKit keeps the LAST tokens and would cut the first terms.
    public static let maxTranscriberPromptCharacters = 500

    /// Summary prompt cap: at most this many terms / characters. Keeps the
    /// glossary line to roughly 100 tokens so it fits Apple's 4096-token window.
    public static let maxSummaryTerms = 40
    public static let maxSummaryCharacters = 300

    /// Trim, drop empties, de-duplicate case-insensitively (first spelling
    /// wins), keep order. Also splits on commas so "Slurm, Lustre" pasted on
    /// one line works.
    public static func normalisedTerms(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for line in terms {
            for piece in line.split(whereSeparator: { $0 == "," || $0 == "\n" }) {
                let term = TranscriptCleaner.normaliseSpace(String(piece))
                guard !term.isEmpty, seen.insert(term.lowercased()).inserted else { continue }
                out.append(term)
            }
        }
        return out
    }

    /// Longest prefix of whole terms whose comma-joined length fits `maxChars`
    /// (and `maxTerms`). Deterministic: earlier terms win, a term is never cut
    /// in half.
    static func capped(_ terms: [String], maxTerms: Int, maxChars: Int) -> [String] {
        var out: [String] = []
        var length = 0
        for term in terms {
            let added = term.count + (out.isEmpty ? 0 : 2)
            if out.count >= maxTerms || length + added > maxChars { break }
            out.append(term)
            length += added
        }
        return out
    }

    /// The text handed to the transcriber as its prompt, or "" for an empty
    /// glossary (callers then send nothing at all). A plain list of terms
    /// reads as a natural vocabulary hint and nudges spelling without
    /// instructing the model (Whisper treats the prompt as prior transcript).
    public static func transcriberPrompt(_ terms: [String]) -> String {
        let kept = capped(normalisedTerms(terms), maxTerms: Int.max,
                          maxChars: maxTranscriberPromptCharacters)
        return kept.isEmpty ? "" : kept.joined(separator: ", ") + "."
    }

    /// The terms the summary prompt names (normalised and capped).
    public static func summaryTerms(_ terms: [String]) -> [String] {
        capped(normalisedTerms(terms), maxTerms: maxSummaryTerms, maxChars: maxSummaryCharacters)
    }

    /// Audio at least this long cannot plausibly be silent, so an empty
    /// prompted transcript counts as the prompt having blanked the output.
    public static let minSecondsForEmptyToBeSuspicious = 30.0

    /// Known Whisper failure with a conditioning prompt: the model parroting
    /// the glossary back as the whole transcript, or (for audio long enough
    /// that silence is implausible) blanking the output. The built-in engine
    /// retries once without the prompt on `true`.
    ///
    /// An echo means the transcript is almost entirely glossary terms: with
    /// every term removed less than 10 letters/digits remain. A recording that
    /// merely OPENS with a glossary word ("Anna, shall we start...") is a good
    /// transcript and is never flagged. A short empty clip is plain silence.
    public static func promptBackfired(transcript: String, terms: [String],
                                       audioSeconds: Double?) -> Bool {
        let text = TranscriptCleaner.normaliseSpace(transcript)
        if text.isEmpty { return (audioSeconds ?? 0) >= minSecondsForEmptyToBeSuspicious }
        var rest = text
        for term in normalisedTerms(terms) {
            rest = rest.replacingOccurrences(of: term, with: "", options: .caseInsensitive)
        }
        let remaining = rest.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.count
        return remaining < 10
    }

    /// The glossary prompt that fits `maxTokens` as measured by `tokenCount`
    /// (the model's real tokenizer). WhisperKit keeps the LAST tokens of an
    /// over-long prompt, which would silently cut the user's FIRST (most
    /// important) terms, so whole terms are dropped from the END here instead.
    public static func transcriberPrompt(_ terms: [String], maxTokens: Int,
                                         tokenCount: (String) -> Int) -> String {
        var kept = capped(normalisedTerms(terms), maxTerms: Int.max,
                          maxChars: maxTranscriberPromptCharacters)
        while !kept.isEmpty {
            let prompt = kept.joined(separator: ", ") + "."
            if tokenCount(" " + prompt) <= maxTokens { return prompt }
            kept.removeLast()
        }
        return ""
    }

    // MARK: Replacement engine

    /// Characters that make up a "word" for boundary purposes: any Unicode
    /// letter or number, a combining mark (decomposed accents) or underscore.
    private static let wordClass = "\\p{L}\\p{N}\\p{M}_"

    /// Apply `rules` in order. Case-insensitive, whole-word (Unicode-aware, so
    /// accented Catalan/Spanish words are not split), multi-word phrases
    /// supported, an empty `from` is ignored, and `to` is inserted literally
    /// (no regex templating). A rule never touches substrings: "cat" leaves
    /// "category" and "concatenate" alone.
    public static func applyReplacements(_ text: String, rules: [ReplacementRule]) -> String {
        var result = text
        for rule in rules {
            let from = rule.from.trimmingCharacters(in: .whitespacesAndNewlines)
            if from.isEmpty { continue }
            // Whitespace inside a phrase matches any run of whitespace.
            let body = from.split(whereSeparator: \.isWhitespace)
                .map { NSRegularExpression.escapedPattern(for: String($0)) }
                .joined(separator: "\\s+")
            let pattern = "(?<![\(wordClass)])\(body)(?![\(wordClass)])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(
                in: result, options: [], range: range,
                withTemplate: NSRegularExpression.escapedTemplate(for: rule.to))
        }
        return result
    }
}
