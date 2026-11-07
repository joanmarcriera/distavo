import Foundation

/// Vikunja #6354: applies the note's own "Possible transcription corrections" to the note body.
///
/// The summariser lists mishearings as `heard "X", probably "Y"` but leaves X elsewhere in the
/// note. After the summary, each pair is applied when the transcript context supports it:
/// X (or one `/`-separated alternative) must occur in the transcript AND in the body outside the
/// section. Replacement is whole-word and case-sensitive. The section itself is kept unchanged as
/// the audit list of what changed. Pure: no I/O. Called from `SummaryChecks.apply`, so
/// `Pipeline.processOne` and `Pipeline.regenerate` both get it. `applied` also feeds the
/// "add to vocabulary" offer (UI, separate step).
public enum TranscriptionCorrections {
    public struct Correction: Equatable, Sendable {
        public let heard: String
        public let corrected: String
    }
    public struct Result: Equatable, Sendable {
        public let text: String
        public let applied: [Correction]
    }

    static let heading = "## possible transcription corrections"

    public static func apply(_ summary: String, transcript: String) -> Result {
        let lines = summary.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).lowercased() == heading }) else {
            return Result(text: summary, applied: [])
        }
        var end = lines.count
        for i in (start + 1)..<lines.count where lines[i].hasPrefix("#") { end = i; break }
        let section = Array(lines[start..<end])
        var head = lines[..<start].joined(separator: "\n")
        var tail = lines[end...].joined(separator: "\n")
        var applied: [Correction] = []
        for pair in parse(section) {
            for heard in pair.heard where heard.count >= 2 && heard.lowercased() != pair.corrected.lowercased() {
                guard occurs(heard, in: transcript) else { continue }
                let h = replace(heard, with: pair.corrected, in: head)
                let t = replace(heard, with: pair.corrected, in: tail)
                if h.changed || t.changed {
                    head = h.text
                    tail = t.text
                    applied.append(Correction(heard: heard, corrected: pair.corrected))
                }
            }
        }
        guard !applied.isEmpty else { return Result(text: summary, applied: []) }
        let text = ([head] + section + (end < lines.count ? [tail] : [])).joined(separator: "\n")
        return Result(text: text, applied: applied)
    }

    /// Footer sentence for the applied count, or nil.
    public static func note(for r: Result) -> String? {
        guard !r.applied.isEmpty else { return nil }
        return "\(r.applied.count) transcription \(r.applied.count == 1 ? "correction" : "corrections") applied"
    }

    private static func parse(_ section: [String]) -> [(heard: [String], corrected: String)] {
        let pat = "heard\\s+[\"\u{201C}]([^\"\u{201D}]+)[\"\u{201D}],?\\s+probably\\s+[\"\u{201C}]([^\"\u{201D}]+)[\"\u{201D}]"
        guard let re = try? NSRegularExpression(pattern: pat, options: .caseInsensitive) else { return [] }
        return section.compactMap { line in
            let ns = line as NSString
            guard let m = re.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
            let heard = ns.substring(with: m.range(at: 1)).split(separator: "/")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let fixed = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
            return heard.isEmpty || fixed.isEmpty ? nil : (heard, fixed)
        }
    }

    private static func regex(_ term: String) -> NSRegularExpression? {
        let p = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: term) + "(?![\\p{L}\\p{N}])"
        return try? NSRegularExpression(pattern: p)
    }

    private static func occurs(_ term: String, in text: String) -> Bool {
        guard let re = regex(term) else { return false }
        return re.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    private static func replace(_ term: String, with new: String, in text: String) -> (text: String, changed: Bool) {
        guard let re = regex(term) else { return (text, false) }
        let r = NSRange(location: 0, length: (text as NSString).length)
        guard re.firstMatch(in: text, range: r) != nil else { return (text, false) }
        let out = re.stringByReplacingMatches(in: text, range: r, withTemplate: NSRegularExpression.escapedTemplate(for: new))
        return (out, true)
    }
}
