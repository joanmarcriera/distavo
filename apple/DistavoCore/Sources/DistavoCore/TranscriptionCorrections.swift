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

    static let headingTitle = "possible transcription corrections"

    /// "## Title", "### Title:", "# **Title**" ... -> true. Any level, optional bold and trailing colon, any case.
    static func isCorrectionsHeading(_ line: String) -> Bool {
        guard isHeading(line) else { return false }
        let title = line.trimmingCharacters(in: .whitespaces).drop(while: { $0 == "#" })
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t*_:#"))
        return title.lowercased() == headingTitle
    }

    /// A markdown ATX heading: 1-6 '#', then a space and text. "#hashtag" and "#2 item" are not headings.
    static func isHeading(_ line: String) -> Bool {
        // Up to three leading spaces are allowed by markdown; four or more is an indented code block.
        let spaces = line.prefix(while: { $0 == " " }).count
        guard spaces <= 3 else { return false }
        let line = line.dropFirst(spaces)
        var n = 0
        for c in line { if c == "#" { n += 1 } else { break } }
        guard (1...6).contains(n) else { return false }
        let rest = line.dropFirst(n)
        return rest.first == " " && !rest.trimmingCharacters(in: .whitespaces).isEmpty
    }

    public static func apply(_ summary: String, transcript: String) -> Result {
        let lines = summary.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: isCorrectionsHeading) else {
            return Result(text: summary, applied: [])
        }
        var end = lines.count
        for i in (start + 1)..<lines.count where isHeading(lines[i]) { end = i; break }
        let section = Array(lines[start..<end])
        var head = lines[..<start].joined(separator: "\n")
        var tail = lines[end...].joined(separator: "\n")
        var applied: [Correction] = []
        for pair in parse(section) {
            for heard in pair.heard where heard.count >= 2 && heard.lowercased() != pair.corrected.lowercased() {
                guard occurs(heard, in: transcript) else { continue }
                let h = replaceOutsideHighlights(heard, with: pair.corrected, in: head)
                let t = replaceOutsideHighlights(heard, with: pair.corrected, in: tail)
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

    /// Fenced blocks, inline code, markdown link targets and bare URLs: text a correction must never rewrite.
    private static let protected = try? NSRegularExpression(
        pattern: "```[\\s\\S]*?(```|\\z)|`[^`\\n]*`|\\]\\([^)\\n]*\\)|https?://[^\\s)>\\]]+",
        options: [])

    /// Splits text into (segment, isProtected) runs.
    private static func runs(_ text: String) -> [(String, Bool)] {
        guard let re = protected else { return [(text, false)] }
        let ns = text as NSString
        var out: [(String, Bool)] = []
        var at = 0
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > at { out.append((ns.substring(with: NSRange(location: at, length: m.range.location - at)), false)) }
            out.append((ns.substring(with: m.range), true))
            at = m.range.location + m.range.length
        }
        if at < ns.length { out.append((ns.substring(from: at), false)) }
        return out
    }

    /// `replace` over a body, skipping any section whose heading contains "highlight": those lines are the typed
    /// Quick Notes of the owner (`ScratchpadNotes`) and are never rewritten. A section runs from its heading to the
    /// next heading outside a code fence (so a sub-heading ends it). Known limit: a heading the model translated
    /// (e.g. "Destacats") is not recognised, and the model commentary under Highlights is protected too.
    private static func replaceOutsideHighlights(_ term: String, with new: String, in text: String) -> (text: String, changed: Bool) {
        var chunks: [(lines: [String], isProtected: Bool)] = [([], false)]
        var inFence = false
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inFence.toggle() }
            if !inFence, isHeading(line) {
                chunks.append(([line], line.lowercased().contains("highlight")))
            } else {
                chunks[chunks.count - 1].lines.append(line)
            }
        }
        var changed = false
        let parts = chunks.map { chunk -> String in
            let joined = chunk.lines.joined(separator: "\n")
            if chunk.isProtected { return joined }
            let r = replace(term, with: new, in: joined)
            changed = changed || r.changed
            return r.text
        }
        return (parts.joined(separator: "\n"), changed)
    }

    /// Replaces `term` outside protected spans and outside existing occurrences of `new`, so `heard "Starling"` ->
    /// `"Starling Bank"` does not turn an already-correct "Starling Bank" into "Starling Bank Bank".
    /// Idempotent on its own output.
    private static func replace(_ term: String, with new: String, in text: String) -> (text: String, changed: Bool) {
        guard let re = regex(term) else { return (text, false) }
        var changed = false
        let out = runs(text).map { (run, isProtected) -> String in
            if isProtected { return run }
            let pieces = run.components(separatedBy: new).map { piece -> String in
                let r = NSRange(location: 0, length: (piece as NSString).length)
                guard re.firstMatch(in: piece, range: r) != nil else { return piece }
                changed = true
                return re.stringByReplacingMatches(in: piece, range: r, withTemplate: NSRegularExpression.escapedTemplate(for: new))
            }
            return pieces.joined(separator: new)
        }
        return (out.joined(), changed)
    }
}
