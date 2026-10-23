// ScaffoldingScrubber.swift — removes prompt scaffolding that small models copy into the note (Vikunja #4010).
//
// Seen with llama3.1:8b + facts-first: "## Step 1: Identify the speakers" / "## Step 2: Facts ledger" /
// "## Step 3: The notes" headings, the ledger repeated under "#### ## Facts ledger", a literal
// "- --- | --- | ---" row, an empty "## Facts ledger  See above.", the instruction sentence verbatim, and a
// closing "Note: The output only includes the notes section, as per the instructions."
// `scrub` is pure and conservative: text without any of these is returned byte-identical.
// It runs in `SummaryChecks.apply`, so `Pipeline.processOne` and `Pipeline.regenerate` both get it.
import Foundation

public enum ScaffoldingScrubber {
    /// Lines that are the prompt talking, never note content.
    private static let instructionMarkers = [
        "decide which speaker label is the note owner",
        "using evidence only",
        "as per the instructions",
        "output only includes the notes",
    ]

    private static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        guard hashes >= 1, hashes <= 6 else { return nil }
        let rest = line.dropFirst(hashes)
        return rest.first == " " || rest.isEmpty ? hashes : nil
    }

    /// "#### ## Facts ledger" -> "## Facts ledger"; "### # Meeting notes" -> "# Meeting notes".
    private static func undouble(_ line: String) -> String {
        guard let first = headingLevel(line) else { return line }
        let rest = String(line.dropFirst(first).drop { $0 == " " })
        guard let second = headingLevel(rest) else { return line }
        let title = String(rest.dropFirst(second).drop { $0 == " " })
        // Only the note's own title is a level-1 heading; any other "# x" the model doubled is a section.
        let level = title.lowercased().hasPrefix("meeting notes") ? second : max(second, 2)
        return String(repeating: "#", count: level) + " " + title
    }

    private static func headingText(_ line: String) -> String {
        line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
    }

    private static func isStepHeading(_ line: String) -> Bool {
        guard headingLevel(line) != nil else { return false }
        return headingText(line).lowercased().range(of: #"^step\s*\d+\b"#, options: .regularExpression) != nil
    }

    /// The real section a "Step N" heading stands for, nil = it has none (drop only the heading).
    private static func sectionTitle(forStep line: String) -> String? {
        let t = headingText(line).lowercased()
        if t.contains("speaker") { return "Speakers" }
        if t.contains("ledger") || t.contains("facts") { return "Facts ledger" }
        return nil
    }

    private static func isFiller(_ s: String) -> Bool {
        let junk = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".()_*"))
        let t = s.trimmingCharacters(in: junk).lowercased()
        return t.isEmpty || t == "see above" || t == "n/a" || t == "none"
    }

    /// A bullet that is only a markdown table rule, e.g. "- --- | --- | ---".
    private static func isTableRuleBullet(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("- ") else { return false }
        let rest = t.dropFirst(2)
        return rest.contains("---") && rest.allSatisfy { "-| :".contains($0) }
    }

    public static func scrub(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n").map(undouble)

        // 1. "Step N" headings: drop the block when the real section exists elsewhere, else rename it.
        var i = 0
        while i < lines.count {
            guard isStepHeading(lines[i]), let level = headingLevel(lines[i]) else { i += 1; continue }
            var end = i + 1
            while end < lines.count, !(headingLevel(lines[end]).map { $0 <= level } ?? false) { end += 1 }
            guard let title = sectionTitle(forStep: lines[i]) else {
                lines.remove(at: i); continue   // "Step 3: The notes": the content stays
            }
            let elsewhere = lines.indices.contains { j in
                (j < i || j >= end) && headingLevel(lines[j]) != nil
                    && headingText(lines[j]).lowercased() == title.lowercased()
            }
            if elsewhere { lines.removeSubrange(i..<end); continue }
            lines[i] = String(repeating: "#", count: level) + " " + title
            i += 1
        }

        // 2. Single lines: a literal table-rule bullet, the prompt's own instructions.
        lines = lines.filter { line in
            if isTableRuleBullet(line) { return false }
            let low = line.lowercased()
            return !instructionMarkers.contains { low.contains($0) }
        }

        // 3. Sections (level >= 2) holding nothing, or only "See above".
        var j = 0
        while j < lines.count {
            guard let level = headingLevel(lines[j]), level >= 2 else { j += 1; continue }
            var end = j + 1
            while end < lines.count, headingLevel(lines[end]) == nil { end += 1 }
            let body = lines[(j + 1)..<end].joined(separator: "\n")
            let nextIsChild = end < lines.count && (headingLevel(lines[end]) ?? 0) > level
            // "## Decisions  See above." keeps its filler on the heading line.
            let words = headingText(lines[j]).components(separatedBy: "  ")
            let headingFiller = words.count > 1 && isFiller(words.dropFirst().joined(separator: " "))
            if isFiller(body) && !nextIsChild && (headingFiller || words.count == 1) {
                lines.removeSubrange(j..<end); continue
            }
            j += 1
        }

        var out = lines.joined(separator: "\n")
        if out == text { return text }
        while out.contains("\n\n\n") { out = out.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return out.trimmingCharacters(in: .newlines) + (text.hasSuffix("\n") ? "\n" : "")
    }
}
