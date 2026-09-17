import Foundation

/// Port of `meeting_pipeline/validate.py`: detect obvious repetition collapse /
/// empty / overlong model output.
public enum SummaryValidator {

    private static let wordRegex = try! NSRegularExpression(
        pattern: "[A-Za-z0-9][A-Za-z0-9'-]*")

    public static func words(from text: String) -> [String] {
        let ns = text as NSString
        let matches = wordRegex.matches(
            in: text, range: NSRange(location: 0, length: ns.length))
        return matches.map { ns.substring(with: $0.range).lowercased() }
    }

    /// Returns the most frequent n-gram and its count. Ties break toward the
    /// first-encountered n-gram, matching Python's `Counter.most_common`.
    public static func mostRepeatedNgram(_ words: [String], size: Int) -> (String, Int) {
        if words.count < size { return ("", 0) }
        var counts: [String: Int] = [:]
        var order: [String] = []
        for i in 0...(words.count - size) {
            let gram = words[i..<(i + size)].joined(separator: " ")
            if counts[gram] == nil { order.append(gram) }
            counts[gram, default: 0] += 1
        }
        var best = ("", 0)
        for gram in order where counts[gram]! > best.1 {
            best = (gram, counts[gram]!)
        }
        return best
    }

    /// True when `text` has a Markdown section heading ("## ...") beyond the
    /// "# Meeting notes" title line — i.e. it's more than a title and a
    /// dangling first bullet (Vikunja #2203: a 105-byte note that stopped
    /// mid-"## Speakers" was saved as a success).
    static func hasSectionHeadingBeyondTitle(_ text: String) -> Bool {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .contains { $0.hasPrefix("## ") }
    }

    public static func validate(
        _ text: String,
        ngramSize: Int = 5,
        maxNgramCount: Int = 16,
        maxChars: Int = 50000,
        minWords: Int = 40
    ) -> [String] {
        var failures: [String] = []
        let isEmpty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if isEmpty {
            failures.append("summary is empty")
        }
        if text.count > maxChars {
            failures.append("summary is unusually long (\(text.count) chars > \(maxChars))")
        }
        let wordList = words(from: text)
        // Not "empty" (which already has its own message) but too thin to be
        // a real note: fewer than `minWords` words, or no section heading
        // beyond the title — a cut-off model response can satisfy neither.
        if !isEmpty && (wordList.count < minWords || !hasSectionHeadingBeyondTitle(text)) {
            failures.append("summary is truncated (\(wordList.count) words)")
        }
        let (gram, count) = mostRepeatedNgram(wordList, size: ngramSize)
        if count > maxNgramCount {
            failures.append("possible repetition collapse: '\(gram)' appears \(count) times")
        }
        return failures
    }
}
