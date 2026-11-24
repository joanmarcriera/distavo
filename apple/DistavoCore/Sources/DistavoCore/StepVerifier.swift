// StepVerifier.swift — every generated plan step needs a quote from the transcript (D059).
//
// "Highest-ROI follow-up" and "30-minute post-meeting plan" invent steps nobody said, and "Key people"
// lists people as involved without evidence. The facts ledger is already checked (`LedgerVerifier`); this
// checks those three sections, matched by heading prefix in English, Catalan and Spanish (accents folded).
// Each bullet or table row must carry a quote ("..." or “...”):
//  - quote found in the transcript (same rule and threshold as `LedgerVerifier.quoteThreshold`) -> kept;
//  - quote not found -> kept and marked " [unverified]";
//  - no quote -> removed. A section left with nothing says "Nothing stated in the meeting."
// Everything else in the note is byte-identical; a second run changes nothing. A transcript under 20
// words is not judged. Pure; wired through `NoteRefinements` behind `summarise.verify_steps` (absent = off;
// on for fresh installs), after `SummaryChecks.apply` (so after `LedgerVerifier` and after
// `SummaryGuards` dropped Key-people names the transcript does not hold). The prompt asks for the quotes
// only when the key is on (`promptBlock`), so the prompt is byte-identical otherwise.

import Foundation

public enum StepVerifier {
    public struct Result: Equatable {
        public var text: String
        public var kept: Int
        public var unverified: Int
        public var removed: Int
        public var checked: Int { kept + unverified + removed }
    }

    public static let emptySection = "Nothing stated in the meeting."

    public static let promptSentence = "Under \"Highest-ROI follow-up\", \"30-minute post-meeting plan\" and \"Key people and organisations\", end every bullet or table row with a short exact quote from the transcript that supports it, in the form (\"...\"). Leave out any step or person nobody mentioned in the meeting."

    /// Prompt addition; "" when off so the prompt stays byte-identical.
    public static func promptBlock(_ on: Bool) -> String { on ? "\n\(promptSentence)\n" : "" }

    /// Folded heading prefixes (lower case, no accents).
    static let headingPrefixes = [
        "highest-roi follow-up", "highest roi follow-up", "30-minute post-meeting plan", "30 minute post-meeting plan",
        "key people",
        "persones clau", "pla posterior de 30 minuts", "pla de 30 minuts", "seguiment de mes valor",
        "seguiment amb mes retorn",
        "personas clave", "plan posterior de 30 minutos", "plan de 30 minutos", "seguimiento de mayor valor",
        "seguimiento con mayor retorno",
    ]

    /// "...", “...”, «...» and ‘...’ (Catalan and Spanish notes quote with «» too).
    private static let quotePattern = try! NSRegularExpression(
        pattern: #""([^"\n]{3,})"|“([^”\n]{3,})”|«([^»\n]{3,})»|‘([^’\n]{3,})’"#)
    private static let separatorRow = try! NSRegularExpression(pattern: #"^\|[\s:|-]+\|?\s*$"#)

    public static func footerNote(_ r: Result) -> String? {
        guard r.checked > 0 else { return nil }
        return "Plan steps checked against the transcript: \(r.kept) kept, \(r.unverified) unverified, \(r.removed) removed (no quote)"
    }

    public static func verify(_ note: String, transcript: String) -> Result {
        let source = LedgerVerifier.tokens(transcript)
        var result = Result(text: note, kept: 0, unverified: 0, removed: 0)
        guard source.count >= 20 else { return result }
        let index = LedgerVerifier.TokenIndex(source)

        let lines = note.components(separatedBy: "\n")
        var out: [String] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            out.append(line)
            i += 1
            guard isHeading(line), isCheckedHeading(line) else { continue }
            // The section runs to the next heading.
            var end = i
            while end < lines.count, !isHeading(lines[end]) { end += 1 }
            out.append(contentsOf: checkSection(Array(lines[i..<end]), index: index, result: &result))
            i = end
        }
        result.text = out.joined(separator: "\n")
        return result
    }

    // MARK: Internals

    static func isHeading(_ line: String) -> Bool { RelativeDates.isHeading(line.trimmingCharacters(in: .whitespaces)) }

    static func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
    }

    static func isCheckedHeading(_ line: String) -> Bool {
        let h = fold(line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces))
        return headingPrefixes.contains { h.hasPrefix($0) }
    }

    private static func isBullet(_ trimmed: String) -> Bool {
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") { return true }
        let digits = trimmed.prefix { $0.isNumber }
        guard !digits.isEmpty else { return false }
        let rest = trimmed.dropFirst(digits.count)
        return rest.hasPrefix(". ") || rest.hasPrefix(") ")
    }

    private static func isSeparator(_ trimmed: String) -> Bool {
        separatorRow.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil
    }

    /// The last quoted span of an item, or nil.
    static func quote(in item: String) -> String? {
        let ns = item as NSString
        guard let m = quotePattern.matches(in: item, range: NSRange(location: 0, length: ns.length)).last else { return nil }
        for g in 1..<m.numberOfRanges where m.range(at: g).location != NSNotFound { return ns.substring(with: m.range(at: g)) }
        return nil
    }

    private static func checkSection(_ body: [String], index: LedgerVerifier.TokenIndex, result: inout Result) -> [String] {
        var out: [String] = []
        var items = 0, left = 0
        func indent(_ s: String) -> Int { s.prefix { $0 == " " || $0 == "\t" }.count }
        var k = 0
        while k < body.count {
            let line = body[k]
            let t = line.trimmingCharacters(in: .whitespaces)
            let tableRow = t.hasPrefix("|")
            let header = tableRow && k + 1 < body.count && isSeparator(body[k + 1].trimmingCharacters(in: .whitespaces))
            guard (isBullet(t) || tableRow), !header, !(tableRow && isSeparator(t)), t != emptySection else {
                out.append(line); k += 1; continue
            }
            // The item: this line and, for a bullet, every following non-blank line indented deeper.
            var children: [String] = []
            var next = k + 1
            if !tableRow {
                while next < body.count, !body[next].trimmingCharacters(in: .whitespaces).isEmpty,
                      indent(body[next]) > indent(line), !body[next].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    children.append(body[next]); next += 1
                }
            }
            k = next
            items += 1
            let whole = ([line] + children).joined(separator: "\n")
            guard let q = quote(in: whole) else { result.removed += 1; continue }
            left += 1
            if whole.contains(LedgerVerifier.unverifiedMarker.trimmingCharacters(in: .whitespaces)) {
                result.unverified += 1; out.append(line); out.append(contentsOf: children); continue
            }
            if index.bestCoverage(of: LedgerVerifier.tokens(q)) >= LedgerVerifier.quoteThreshold {
                result.kept += 1; out.append(line)
            } else {
                result.unverified += 1; out.append(marked(line, tableRow: tableRow))
            }
            out.append(contentsOf: children)
        }
        guard items > 0, left == 0 else { return out }
        // Nothing left: drop an orphaned table header and separator, say so once under the heading.
        var cleaned: [String] = []
        for (k, line) in out.enumerated() {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("|") && (isSeparator(t) || (k + 1 < out.count && isSeparator(out[k + 1].trimmingCharacters(in: .whitespaces)))) {
                continue
            }
            cleaned.append(line)
        }
        if !cleaned.contains(where: { $0.trimmingCharacters(in: .whitespaces) == emptySection }) {
            cleaned.insert(emptySection, at: 0)
        }
        return cleaned
    }

    private static func marked(_ line: String, tableRow: Bool) -> String {
        let marker = LedgerVerifier.unverifiedMarker
        guard tableRow else { return line + marker }
        var trimmed = line
        while trimmed.hasSuffix(" ") { trimmed.removeLast() }
        guard trimmed.hasSuffix("|") else { return line + marker }
        trimmed.removeLast()
        while trimmed.hasSuffix(" ") { trimmed.removeLast() }
        return trimmed + marker + " |"
    }
}
