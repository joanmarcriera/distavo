// FuzzyVocabulary.swift — a post-ASR pass that snaps near-miss spellings to the user's vocabulary (Vikunja #3950).
//
// Why: Parakeet takes no prompt, so `transcribe.vocabulary` never reached it ("Slurm" came out "Slorm").
// This pass looks at the finished transcript text and, for each vocabulary term, finds words (or runs of up to
// three words) that are a small edit away from it, and returns plain `ReplacementRule`s, so the existing
// whole-word replacement machinery (clean transcript, timed segments, exports) does the rewriting.
//
// Deliberately conservative, because a wrong rewrite is worse than a missed one:
//  - only terms of at least 5 letters (a 4-letter term such as "Bull" would capture "bill", "ball", "bell");
//  - same first letter; edit distance <= 1 (<= 2 from 8 letters up) on the lower-case, space-free form;
//  - a candidate that is itself another vocabulary term is never rewritten;
//  - an all-lower-case exact match is capitalised the way the term is written; a differently-capitalised one
//    (a proper noun the speaker meant) is left alone.
// Off unless `transcribe.fuzzy_vocabulary` is true. Pure: no I/O.
import Foundation

public enum FuzzyVocabulary {
    /// Longest run of words that may be glued back into one term ("Voltage Park" is two words).
    static let maxWords = 3
    /// Upper bound on rules per recording (a runaway vocabulary must not slow the clean step).
    static let maxRules = 200

    public static func rules(terms: [String], text: String) -> [ReplacementRule] {
        let terms = Vocabulary.normalisedTerms(terms)
        let keys = Set(terms.map { squash($0) })
        let tokens = tokenise(text)
        guard !terms.isEmpty, !tokens.isEmpty else { return [] }
        var seen = Set<String>()
        var out: [ReplacementRule] = []
        for term in terms {
            let target = squash(term)
            guard target.count >= 5, let first = target.first else { continue }
            let limit = target.count >= 8 ? 2 : 1
            let wordCount = max(1, term.split(separator: " ").count)
            for n in Set([wordCount, 1]).sorted(by: >) where n <= maxWords {
                guard tokens.count >= n else { continue }
                for i in 0...(tokens.count - n) {
                    let window = Array(tokens[i..<(i + n)])
                    // Words inside a run must follow each other with no punctuation between them.
                    guard window.dropLast().allSatisfy({ !$0.endsWithPunctuation }) else { continue }
                    guard !window.contains(where: { $0.word == "\u{0}" }) else { continue }
                    let raw = window.map(\.word).joined(separator: " ")
                    let candidate = squash(raw)
                    guard candidate.first == first, candidate.count >= 4 else { continue }
                    if raw == term { continue }
                    if keys.contains(candidate), candidate != target { continue }
                    if candidate == target {
                        // Same letters: fix only an all-lower-case rendering.
                        guard raw == raw.lowercased() else { continue }
                    } else if LedgerVerifier.editDistance(candidate, target, limit: limit) == nil {
                        continue
                    }
                    if seen.insert(raw.lowercased()).inserted {
                        out.append(ReplacementRule(from: raw, to: term))
                        if out.count >= maxRules { return out }
                    }
                }
            }
        }
        return out
    }

    // MARK: Internals

    private struct Token {
        let word: String
        let endsWithPunctuation: Bool
    }

    /// Whitespace-separated words, edge punctuation trimmed. A word with punctuation inside (a URL, "it's")
    /// is dropped: it is not a spelling variant of a vocabulary term.
    private static func tokenise(_ text: String) -> [Token] {
        var out: [Token] = []
        for piece in text.split(whereSeparator: { $0.isWhitespace }) {
            let s = String(piece)
            let trimmedStart = s.drop(while: { !$0.isLetter && !$0.isNumber })
            let core = String(trimmedStart.reversed().drop(while: { !$0.isLetter && !$0.isNumber }).reversed())
            guard !core.isEmpty, core.allSatisfy({ $0.isLetter || $0.isNumber }) else {
                // Break the run: a placeholder that can never match.
                out.append(Token(word: "\u{0}", endsWithPunctuation: true))
                continue
            }
            out.append(Token(word: core, endsWithPunctuation: s.last.map { !$0.isLetter && !$0.isNumber } ?? false))
        }
        return out
    }

    /// Lower case, accents folded, only letters and digits (so "Voltage Park" == "voltagepark").
    private static func squash(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
