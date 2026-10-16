import Foundation

// "Learn from this transcript" (Vikunja #3584): turns the corrections a user made in the transcript
// editor into suggested replacement rules ("heard" -> "write") and vocabulary terms, so the next
// recording gets them right. Pure: it only diffs two texts; the app decides what to store.

public enum CorrectionLearner {

    /// Longest run of words, on either side, that counts as one correction. Longer rewrites are edits
    /// to the meaning, not a mis-heard word.
    static let maxRunWords = 3

    /// Suggested rules from the segment texts before and after editing (paired by position; if the
    /// counts differ the texts are diffed as one block). Order of first appearance, one per `from`.
    public static func suggestions(original: [String], edited: [String]) -> [ReplacementRule] {
        let pairs: [(String, String)] = original.count == edited.count
            ? Array(zip(original, edited)) : [(original.joined(separator: " "), edited.joined(separator: " "))]
        var seen = Set<String>()
        var out: [ReplacementRule] = []
        for (a, b) in pairs where a != b {
            for rule in diff(a, b) where seen.insert(rule.from.lowercased()).inserted { out.append(rule) }
        }
        return out
    }

    /// Terms worth adding to the vocabulary: the "write" side of a rule when it looks like a name or
    /// acronym (has a capital letter), de-duplicated against `existing` case-insensitively.
    public static func vocabularyTerms(for rules: [ReplacementRule], existing: [String]) -> [String] {
        var have = Set(Vocabulary.normalisedTerms(existing).map { $0.lowercased() })
        var out: [String] = []
        for r in rules where r.to.contains(where: \.isUppercase) && have.insert(r.to.lowercased()).inserted {
            out.append(r.to)
        }
        return out
    }

    /// `rules` minus the ones already present (same `from`, case-insensitive) in `existing`.
    public static func newRules(_ rules: [ReplacementRule], existing: [ReplacementRule]) -> [ReplacementRule] {
        let have = Set(existing.map { $0.from.lowercased() })
        return rules.filter { !have.contains($0.from.lowercased()) }
    }

    // MARK: Diff

    private static let edge = CharacterSet.punctuationCharacters.union(.symbols).union(.whitespacesAndNewlines)

    /// Words without the punctuation hugging them ("ERP," -> "ERP"); inner apostrophes stay.
    private static func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: edge) }
            .filter { !$0.isEmpty }
    }

    static func diff(_ a: String, _ b: String) -> [ReplacementRule] {
        let x = words(a), y = words(b)
        guard !x.isEmpty, !y.isEmpty else { return [] }
        // Longest common subsequence table (segments are short: a few dozen words).
        var l = Array(repeating: Array(repeating: 0, count: y.count + 1), count: x.count + 1)
        for i in stride(from: x.count - 1, through: 0, by: -1) {
            for j in stride(from: y.count - 1, through: 0, by: -1) {
                l[i][j] = x[i] == y[j] ? l[i + 1][j + 1] + 1 : max(l[i + 1][j], l[i][j + 1])
            }
        }
        var out: [ReplacementRule] = []
        var i = 0, j = 0
        var oldRun: [String] = [], newRun: [String] = []
        func flush() {
            defer { oldRun = []; newRun = [] }
            guard !oldRun.isEmpty, !newRun.isEmpty,
                  oldRun.count <= maxRunWords, newRun.count <= maxRunWords else { return }
            let from = oldRun.joined(separator: " "), to = newRun.joined(separator: " ")
            guard from.count >= 2, from != to else { return }
            // A change of capitals only is a correction when it makes an acronym or a name.
            if from.lowercased() == to.lowercased(),
               !newRun.contains(where: { $0.dropFirst().contains(where: \.isUppercase) }) { return }
            // A bare number is a different fact, not a mis-hearing.
            if from.allSatisfy({ $0.isNumber || $0 == " " }) { return }
            out.append(ReplacementRule(from: from, to: to))
        }
        while i < x.count || j < y.count {
            if i < x.count, j < y.count, x[i] == y[j] { flush(); i += 1; j += 1 }
            else if j >= y.count || (i < x.count && l[i + 1][j] >= l[i][j + 1]) { oldRun.append(x[i]); i += 1 }
            else { newRun.append(y[j]); j += 1 }
        }
        flush()
        return out
    }
}
