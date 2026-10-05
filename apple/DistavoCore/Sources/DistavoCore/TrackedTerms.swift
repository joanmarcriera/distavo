import Foundation

// Tracked terms (Vikunja #2954): words the user wants flagged wherever they come up
// ("pricing", "GDPR", a project name). For every configured term found in the transcript
// the note gets a `## Tracked terms` section with one line per mention
//
//     - [03:12] **Slurm** — "…we moved the Slurm cluster to the new rack…" (SPEAKER_00)
//
// and the term becomes a tag. No model is involved, so it works with every backend; it
// matches whole words, case-insensitively and Unicode-aware via `Vocabulary.wholeWordRegex`
// (so "cat" does not flag "category", and accented Catalan/Spanish terms work).
//
// Source of timestamps: the timed segments (`<base>.segments.json`). A text-only result
// (WhisperX server without timings) falls back to the cleaned transcript and the lines
// carry no timestamp. One line per matching SEGMENT and term (a segment mentioning a
// term twice is one line), capped per term.

public enum TrackedTerms {

    /// Lines shown per term before "and N more".
    public static let maxLinesPerTerm = 10
    /// Characters of context kept on each side of the match.
    public static let contextRadius = 60

    public struct Hit: Equatable, Sendable {
        public var seconds: Double?
        public var speaker: String?
        public var context: String
    }

    public struct Report: Equatable, Sendable {
        public var term: String
        /// Every matching segment, in transcript order (not capped).
        public var hits: [Hit]
    }

    /// One transcript turn as the matcher sees it.
    public struct Turn: Equatable, Sendable {
        public var seconds: Double?
        public var speaker: String?
        public var text: String
        public init(seconds: Double?, speaker: String?, text: String) {
            self.seconds = seconds; self.speaker = speaker; self.text = text
        }
    }

    public static func turns(from segments: TranscriptSegments) -> [Turn] {
        segments.segments.map { Turn(seconds: $0.start, speaker: $0.speaker, text: $0.text) }
    }

    /// Turns parsed from the cleaned transcript (`[SPEAKER_00]\ntext` blocks), untimed.
    public static func turns(fromCleanTranscript clean: String) -> [Turn] {
        var out: [Turn] = []
        for block in clean.components(separatedBy: "\n\n") {
            let lines = block.components(separatedBy: "\n")
            guard let head = lines.first else { continue }
            if head.hasPrefix("["), head.hasSuffix("]"), lines.count > 1 {
                let speaker = String(head.dropFirst().dropLast())
                out.append(Turn(seconds: nil, speaker: speaker, text: lines.dropFirst().joined(separator: " ")))
            } else {
                out.append(Turn(seconds: nil, speaker: nil, text: block))
            }
        }
        return out
    }

    /// Terms that occur, in the order configured. Terms with no occurrence are omitted.
    public static func find(terms: [String], in turns: [Turn]) -> [Report] {
        var reports: [Report] = []
        for term in Vocabulary.normalisedTerms(terms) {
            guard let regex = Vocabulary.wholeWordRegex(term) else { continue }
            var hits: [Hit] = []
            for turn in turns {
                let ns = turn.text as NSString
                guard let m = regex.firstMatch(in: turn.text, range: NSRange(location: 0, length: ns.length)) else { continue }
                hits.append(Hit(seconds: turn.seconds, speaker: turn.speaker,
                                context: context(in: turn.text, around: m.range)))
            }
            if !hits.isEmpty { reports.append(Report(term: term, hits: hits)) }
        }
        return reports
    }

    /// A short excerpt around the match, snapped to word boundaries, "…" where cut.
    static func context(in text: String, around range: NSRange) -> String {
        let ns = text as NSString
        var lo = max(0, range.location - contextRadius)
        var hi = min(ns.length, range.location + range.length + contextRadius)
        // Snap inward to a space so no word is cut in half.
        if lo > 0 {
            let r = ns.range(of: " ", range: NSRange(location: lo, length: range.location - lo))
            if r.location != NSNotFound { lo = r.location + 1 }
        }
        if hi < ns.length {
            let from = range.location + range.length
            let r = ns.range(of: " ", options: .backwards, range: NSRange(location: from, length: hi - from))
            if r.location != NSNotFound { hi = r.location }
        }
        var excerpt = ns.substring(with: NSRange(location: lo, length: max(0, hi - lo)))
            .replacingOccurrences(of: "\"", with: "'")
        excerpt = TranscriptCleaner.normaliseSpace(excerpt)
        return (lo > 0 ? "…" : "") + excerpt + (hi < ns.length ? "…" : "")
    }

    /// `mm:ss`, or `h:mm:ss` from one hour.
    public static func timestamp(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    /// The `## Tracked terms` Markdown section (starts with a blank line, ends with "\n"),
    /// or "" when nothing was found.
    public static func section(_ reports: [Report]) -> String {
        guard !reports.isEmpty else { return "" }
        var lines = ["", "## Tracked terms", ""]
        for report in reports {
            for hit in report.hits.prefix(maxLinesPerTerm) {
                var line = "- "
                if let s = hit.seconds { line += "[\(timestamp(s))] " }
                line += "**\(report.term)** — \"\(hit.context)\""
                if let sp = hit.speaker, !sp.isEmpty, sp != "SPEAKER_UNKNOWN" { line += " (\(sp))" }
                lines.append(line)
            }
            let more = report.hits.count - maxLinesPerTerm
            if more > 0 { lines.append("- _…and \(more) more \(more == 1 ? "mention" : "mentions") of **\(report.term)**._") }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The tags for the terms that occurred.
    public static func tags(_ reports: [Report]) -> [String] {
        reports.compactMap { NoteMeta.slug($0.term) }
    }
}
