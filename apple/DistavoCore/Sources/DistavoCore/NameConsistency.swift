import Foundation

/// Flags first names that look like one person spelled several ways inside ONE note
/// ("Katrin / Katrina / Katarina / Katryn": speech-to-text drift, drive 2026-11-22).
///
/// It never rewrites the note: two real people can be called Marc and Mark. It only reports the group, as a footer
/// sentence, so the owner can fix the participants line or add a replacement and regenerate.
/// Pure. Opt-in through `summarise.name_check` (off for a config predating the key).
public enum NameConsistency {
    /// Same first letter and similarity at or above this (Jaro-Winkler) make two names one group.
    static let threshold = 0.82
    static let minLength = 4

    /// Words that start with a capital but are not names: headings, labels, days, months and common sentence starters.
    private static let stop: Set<String> = [
        "the", "this", "that", "these", "those", "there", "then", "they", "their", "with", "from", "have", "will", "would",
        "meeting", "notes", "speaker", "speakers", "owner", "note", "summary", "action", "actions", "owner", "deadline",
        "evidence", "confidence", "highlights", "decisions", "follow", "email", "unclear", "none", "stated", "employer",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "january", "february", "march",
        "april", "june", "july", "august", "september", "october", "november", "december", "what", "when", "where",
        "which", "while", "key", "people", "role", "next", "steps", "step", "high", "medium", "low", "thank", "thanks",
        "regards", "hello", "best", "also", "about", "after", "before", "because", "should", "could", "does", "were",
        "been", "being", "into", "over", "under", "other", "some", "each", "every", "both", "please", "teams",
    ]

    /// Groups of two or more distinct spellings, each group sorted, groups ordered by first appearance.
    public static func suspectGroups(in note: String) -> [[String]] {
        var order: [String] = []
        var seen = Set<String>()
        for line in note.split(separator: "\n", omittingEmptySubsequences: true) {
            let text = String(line)
            if text.hasPrefix("#") || text.hasPrefix("_Summary:") { continue }       // headings, our own footer
            // A bullet or table row ("- Katrin: ...", "| Katrin |") starts with a label that may be a name; a prose
            // line starts with a capitalised ordinary word, which is not evidence of one.
            let marked = text.drop(while: { $0 == " " }).first.map { "-*|>".contains($0) || $0.isNumber } ?? false
            for (i, tok) in tokens(text).enumerated() {
                // A capitalised word that opens a sentence is not evidence of a name; a bullet or table row
                // ("- Katrin: ...", "| Katrin |") starts with a label that may be one.
                if (i == 0 && !marked) || tok.afterSentenceEnd { continue }
                let word = tok.word
                guard isCandidate(word), seen.insert(word).inserted else { continue }
                order.append(word)
            }
        }
        // union-find by similarity
        var parent = Array(order.indices)
        func find(_ x: Int) -> Int { var r = x; while parent[r] != r { r = parent[r] }; return r }
        for i in order.indices {
            for j in order.indices where j > i && similar(order[i], order[j]) {
                parent[find(j)] = find(i)
            }
        }
        var groups: [Int: [String]] = [:]
        var firstIndex: [Int: Int] = [:]
        for i in order.indices {
            let r = find(i)
            groups[r, default: []].append(order[i])
            if firstIndex[r] == nil { firstIndex[r] = i }
        }
        return groups.filter { $0.value.count >= 2 }
            .sorted { firstIndex[$0.key]! < firstIndex[$1.key]! }
            .map { $0.value.sorted() }
    }

    /// The footer sentence for `suspectGroups`, or nil when there is nothing to say.
    public static func note(for groups: [[String]]) -> String? {
        guard !groups.isEmpty else { return nil }
        let parts = groups.prefix(3).map { $0.joined(separator: " / ") }
        return "Names that may be one person spelled several ways: " + parts.joined(separator: "; ")
            + ". Check them, fix them with Rename Speakers (or the participants line next time)"
    }

    // MARK: Internals

    /// Words of a line with whether a sentence end (. ? !) came right before each. A trailing possessive
    /// ('s or the curly form) is dropped so "Priya" and "Priya's" are one word.
    private static func tokens(_ line: String) -> [(word: String, afterSentenceEnd: Bool)] {
        var out: [(String, Bool)] = []
        var word = ""
        var lastMark: Character?
        func flush() {
            guard !word.isEmpty else { return }
            var w = word
            for suffix in ["'s", "\u{2019}s", "'", "\u{2019}"] where w.hasSuffix(suffix) {
                w = String(w.dropLast(suffix.count)); break
            }
            out.append((w, lastMark.map { ".?!".contains($0) } ?? false))
            word = ""; lastMark = nil
        }
        for ch in line {
            if ch.isLetter || ((ch == "'" || ch == "\u{2019}") && !word.isEmpty) { word.append(ch) }
            else {
                flush()
                if !" \t*_-|>\"'(".contains(ch) { lastMark = ch }
            }
        }
        flush()
        return out
    }

    private static func isCandidate(_ w: String) -> Bool {
        guard w.count >= minLength, let f = w.first, f.isUppercase else { return false }
        // ALL CAPS is an acronym or a label (NVIDIA, SPEAKER), not a name.
        if w == w.uppercased() { return false }
        return !stop.contains(w.lowercased())
    }

    static func similar(_ a: String, _ b: String) -> Bool {
        let x = a.lowercased(), y = b.lowercased()
        guard x != y, x.first == y.first, !isInflection(x, y) else { return false }
        return jaroWinkler(x, y) >= threshold
    }

    /// "Server"/"Servers", "Opportunity"/"Opportunities": a plural is the same word, not a second person.
    static func isInflection(_ a: String, _ b: String) -> Bool {
        let (short, long) = a.count <= b.count ? (a, b) : (b, a)
        if long == short + "s" || long == short + "es" { return true }
        return short.hasSuffix("y") && long == short.dropLast() + "ies"
    }

    static func jaroWinkler(_ s1: String, _ s2: String) -> Double {
        let a = Array(s1), b = Array(s2)
        if a.isEmpty || b.isEmpty { return 0 }
        let window = max(0, max(a.count, b.count) / 2 - 1)
        var aMatched = [Bool](repeating: false, count: a.count)
        var bMatched = [Bool](repeating: false, count: b.count)
        var matches = 0
        for i in a.indices {
            let lo = max(0, i - window), hi = min(b.count - 1, i + window)
            guard lo <= hi else { continue }
            for j in lo...hi where !bMatched[j] && a[i] == b[j] {
                aMatched[i] = true; bMatched[j] = true; matches += 1; break
            }
        }
        guard matches > 0 else { return 0 }
        var t = 0, k = 0
        for i in a.indices where aMatched[i] {
            while !bMatched[k] { k += 1 }
            if a[i] != b[k] { t += 1 }
            k += 1
        }
        let m = Double(matches)
        let jaro = (m / Double(a.count) + m / Double(b.count) + (m - Double(t) / 2) / m) / 3
        var prefix = 0
        for i in 0..<min(4, min(a.count, b.count)) { if a[i] == b[i] { prefix += 1 } else { break } }
        return jaro + Double(prefix) * 0.1 * (1 - jaro)
    }
}
