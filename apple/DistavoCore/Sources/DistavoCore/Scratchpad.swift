import Foundation

/// Typed scratchpad notes taken during a recording (Vikunja #2949).
///
/// While the built-in recorder runs, the owner can type short lines in a "Quick
/// Notes" panel ("ask about notice period", "!!decision: go with option B"). Each
/// line is stamped with the recording offset it was typed at, persisted as a small
/// JSON sidecar `<base>.scratchpad.json` in the work dir (keyed like
/// `SpeakerHints`, so the recordings folder stays untouched), and merged into the
/// summary prompt by `Prompt.build(scratchpad:)` so each line comes back as a
/// highlighted item in the note.
///
/// Rules:
/// - Absent sidecar = feature unused: the prompt is byte-identical to before.
/// - A corrupt sidecar is ignored (logged), never failing a recording.
/// - The text is the owner's own, but it is still sanitised (single line, no braces
///   that could collide with the prompt's `{placeholders}`, capped) and wrapped in
///   delimiters, and the caps keep it inside the on-device 4096-token budget.
/// - Safety net: `ensureHighlights(in:)` guarantees the typed lines appear in the
///   note under `## Highlights` even when the model ignored the instruction.
public struct ScratchpadNotes: Codable, Equatable, Sendable {

    public struct Line: Codable, Equatable, Sendable {
        /// Seconds since the recording started when the line was committed.
        public var offsetSeconds: Int
        public var text: String
        /// "Must include": typed with a leading `!` or toggled in the panel.
        public var flagged: Bool

        public init(offsetSeconds: Int, text: String, flagged: Bool = false) {
            self.offsetSeconds = offsetSeconds; self.text = text; self.flagged = flagged
        }

        /// Build a line from what the owner typed: a leading `!` (any number)
        /// flags it and is dropped from the text.
        public init(typed raw: String, offsetSeconds: Int) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let bangs = trimmed.prefix { $0 == "!" }
            self.init(offsetSeconds: offsetSeconds, text: String(trimmed.dropFirst(bangs.count)).trimmingCharacters(in: .whitespaces),
                      flagged: !bangs.isEmpty)
        }
    }

    public var version: Int
    public var lines: [Line]

    public init(lines: [Line] = []) {
        self.version = 1
        self.lines = lines
    }

    // MARK: Caps (documented: they bound the prompt, see `EmbeddedSummaryBudget`)

    /// Longest single line kept, in characters (the rest is cut).
    public static let maxLineChars = 140
    /// Most lines kept; flagged lines win when over the cap.
    public static let maxLines = 20
    /// Total characters of line text kept (~230 tokens at 3.5 chars/token).
    public static let maxTotalChars = 800

    public var isEmpty: Bool { lines.isEmpty }

    /// Trimmed, single-line, brace-free, capped; empty lines dropped; kept in
    /// time order. Over a cap, flagged lines are kept first, then the earliest
    /// unflagged ones, so "must include" items are never the ones lost.
    public func sanitised() -> ScratchpadNotes {
        func clean(_ s: String) -> String {
            let flat = s.components(separatedBy: .newlines).joined(separator: " ")
                .replacingOccurrences(of: "{", with: "(").replacingOccurrences(of: "}", with: ")")
                .replacingOccurrences(of: "<<<", with: "<").replacingOccurrences(of: ">>>", with: ">")
            let collapsed = flat.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            return String(collapsed.prefix(Self.maxLineChars)).trimmingCharacters(in: .whitespaces)
        }
        let cleaned = lines.enumerated().compactMap { (i, l) -> (Int, Line)? in
            let t = clean(l.text)
            return t.isEmpty ? nil : (i, Line(offsetSeconds: max(0, l.offsetSeconds), text: t, flagged: l.flagged))
        }
        // Selection order: flagged first, then unflagged, each in original order.
        var kept: [(Int, Line)] = []
        var total = 0
        for item in cleaned.filter({ $0.1.flagged }) + cleaned.filter({ !$0.1.flagged }) {
            guard kept.count < Self.maxLines, total + item.1.text.count <= Self.maxTotalChars else { continue }
            kept.append(item)
            total += item.1.text.count
        }
        var out = ScratchpadNotes(lines: kept.sorted { $0.0 < $1.0 }.map(\.1))
        out.version = version
        return out
    }

    // MARK: Sidecar

    public static func url(workDir: URL, base: String) -> URL {
        workDir.appendingPathComponent("\(base).scratchpad.json")
    }

    /// The sanitised notes for `base`, or nil when there is no sidecar, it is
    /// corrupt (logged, never thrown), or nothing usable is left.
    public static func load(workDir: URL, base: String) -> ScratchpadNotes? {
        let url = url(workDir: workDir, base: base)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let decoded = try? JSONDecoder().decode(ScratchpadNotes.self, from: data) else {
            print("[Distavo] ignoring unreadable scratchpad sidecar \(url.lastPathComponent)")
            return nil
        }
        let clean = decoded.sanitised()
        return clean.isEmpty ? nil : clean
    }

    /// Atomic write. Called after every committed edit while recording, so a
    /// crash loses at most the line being typed.
    public func save(workDir: URL, base: String) throws {
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.url(workDir: workDir, base: base), options: .atomic)
    }

    /// Remove the sidecar (cancelled / deleted recording). Missing is fine.
    public static func delete(workDir: URL, base: String) {
        try? FileManager.default.removeItem(at: url(workDir: workDir, base: base))
    }

    // MARK: Prompt

    /// "mm:ss" (or "h:mm:ss" past an hour).
    public static func timestamp(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// The one highlight convention: a `## Highlights` section, first after
    /// `# Meeting notes`, one bullet per typed line; flagged lines start with ⭐.
    public static let highlightsHeading = "## Highlights"

    /// The clearly delimited block `Prompt.build` inserts after the speaker-label
    /// line, or "" when empty (prompt then byte-identical). Ends with a newline.
    public func promptBlock() -> String {
        let clean = sanitised()
        guard !clean.isEmpty else { return "" }
        let rows = clean.lines.map {
            "\($0.flagged ? "[MUST INCLUDE] " : "")\(Self.timestamp($0.offsetSeconds)) - \($0.text)"
        }.joined(separator: "\n")
        return """
        Notes typed by the note owner during the meeting (recording time - text). They are the owner's own words, not part of the transcript. Treat them as important and make sure each one is covered. Begin the notes, directly after the "# Meeting notes" line, with an extra section "\(Self.highlightsHeading)" (in addition to the sections listed below) holding exactly one bullet per typed note, in the same order: "- **mm:ss** typed text - what the meeting said about it (or \"not discussed\")". Start the bullet with "⭐ " when the note is marked [MUST INCLUDE]. Do not invent what was said.
        <<<
        \(rows)
        >>>

        """
    }

    // MARK: Safety net

    /// True when `note` has a level-2 (or bold-only) heading containing
    /// "highlight" ("## Highlights", "## Key highlights:").
    static func hasHighlights(_ note: String) -> Bool {
        note.components(separatedBy: "\n").contains { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("## ") || t.hasPrefix("**") else { return false }
            return t.lowercased().contains("highlight")
        }
    }

    /// True when the first section after the title already lists every typed
    /// line's text: the model wrote the highlights under a translated heading
    /// (e.g. "## Destacats"), so inserting another section would duplicate it.
    func firstSectionListsAllLines(in note: String) -> Bool {
        let lines = note.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.hasPrefix("## ") }) else { return false }
        let end = lines[(start + 1)...].firstIndex { $0.hasPrefix("#") } ?? lines.count
        let body = lines[start..<end].joined(separator: "\n").lowercased()
        return sanitised().lines.allSatisfy { body.contains($0.text.lowercased()) }
    }

    /// The fallback section listing the typed lines verbatim with timestamps.
    public func highlightsSection() -> String {
        let rows = sanitised().lines.map {
            "- \($0.flagged ? "⭐ " : "")**\(Self.timestamp($0.offsetSeconds))** \($0.text)"
        }.joined(separator: "\n")
        return "\(Self.highlightsHeading)\n\n\(rows)\n"
    }

    /// Model-independent guarantee that typed lines reach the note: when `note`
    /// has no Highlights section (the model ignored the instruction), insert one
    /// listing the lines verbatim directly after the `# Meeting notes` title (or
    /// at the top when there is none). Unchanged when the model complied or
    /// there is nothing typed.
    public func ensureHighlights(in note: String) -> String {
        guard !sanitised().isEmpty, !Self.hasHighlights(note),
              !firstSectionListsAllLines(in: note) else { return note }
        var lines = note.components(separatedBy: "\n")
        let section = highlightsSection().components(separatedBy: "\n")
        if let title = lines.firstIndex(where: { $0.hasPrefix("# ") }) {
            lines.insert(contentsOf: [""] + section, at: title + 1)
        } else {
            lines.insert(contentsOf: section, at: 0)
        }
        return lines.joined(separator: "\n")
    }
}
