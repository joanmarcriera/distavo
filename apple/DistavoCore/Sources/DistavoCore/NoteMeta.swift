import Foundation

// LLM-suggested title and tags (Vikunja #2954).
//
// When `notes.auto_title` / `notes.auto_tags` are on, the summariser is asked - in the
// SAME prompt, as extra instruction text riding the existing `customInstruction` channel
// (so it reaches Ollama, Gemma and Apple's on-device model, and is counted by the
// Foundation Models budget) - to end its answer with two machine-readable lines:
//
//     Distavo-Title: Q4 roadmap review
//     Distavo-Tags: roadmap, hiring, budget
//
// `extract` parses them leniently (case, markdown decoration, bullets), REMOVES them
// from the note body and sanitises the values. A missing or malformed line yields nil /
// no tags - it never fails a recording. With both options off nothing here runs and the
// prompt and note are byte-identical to before.

public enum NoteMeta {

    public static let titlePrefix = "Distavo-Title:"
    public static let tagsPrefix = "Distavo-Tags:"
    public static let maxTags = 6
    public static let maxTitleChars = 80

    /// The extra instruction text for the enabled options ("" when none is on).
    public static func requestText(_ notes: NotesConfig) -> String {
        guard notes.asksModelForMetadata else { return "" }
        var lines: [String] = []
        if notes.wantsTitle {
            lines.append("\(titlePrefix) <a specific title for this meeting, at most 10 words, no quotes>")
        }
        if notes.wantsTags {
            lines.append("\(tagsPrefix) <3 to 6 lowercase topic keywords, comma-separated, no # signs>")
        }
        return "After the notes, end your answer with exactly "
            + (lines.count == 1 ? "this line" : "these \(lines.count) lines")
            + " and nothing after \(lines.count == 1 ? "it" : "them"):\n" + lines.joined(separator: "\n")
    }

    /// The custom-instruction string to hand the prompt: the user's own (Regenerate)
    /// instruction followed by the title/tags request. Returns `userInstruction`
    /// untouched (nil stays nil) when both options are off. The user's text is cut
    /// so the pair still fits `Prompt.maxCustomInstructionChars` (the request is kept whole).
    public static func mergedInstruction(_ userInstruction: String?, notes: NotesConfig) -> String? {
        let request = requestText(notes)
        if request.isEmpty { return userInstruction }
        let room = max(0, Prompt.maxCustomInstructionChars - request.count - 2)
        let user = String((userInstruction ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(room))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return user.isEmpty ? request : user + "\n\n" + request
    }

    // MARK: Title sidecar
    //
    // The model's title is kept in `<workDir>/<base>.title.txt` so the vault copy can be named
    // by it whatever the frontmatter switch says, and a later refresh (speaker rename) still knows it.

    public static func titleURL(workDir: URL, base: String) -> URL {
        workDir.appendingPathComponent("\(base).title.txt")
    }

    public static func loadTitle(workDir: URL, base: String) -> String? {
        (try? String(contentsOf: titleURL(workDir: workDir, base: base), encoding: .utf8))
            .flatMap(sanitisedTitle)
    }

    /// Remember `title`; nil removes a stale one. Best effort, never throws.
    public static func storeTitle(_ title: String?, workDir: URL, base: String) {
        let url = titleURL(workDir: workDir, base: base)
        if let title {
            try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
            try? title.write(to: url, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    public struct Extracted: Equatable, Sendable {
        /// The text with every title/tags line removed.
        public var body: String
        public var title: String?
        public var tags: [String]
    }

    private static let lineRegex = try! NSRegularExpression(
        pattern: #"^[ \t>*_`\-]*Distavo[-_ ]?(Title|Tags)[ \t]*[*_`]*[ \t]*:[ \t]*[*_`]*[ \t]*(.*)$"#,
        options: [.caseInsensitive])

    /// Pulls the title/tags lines out of `text`. Only call when an option is on; the
    /// lines are removed even if the model emitted a kind that was not asked for.
    /// The LAST occurrence of each wins (chunked summaries may repeat them).
    public static func extract(from text: String) -> Extracted {
        var title: String?, tags: [String] = []
        var kept: [String] = []
        var removed = false
        for line in text.components(separatedBy: "\n") {
            let ns = line as NSString
            if let m = lineRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                removed = true
                let kind = ns.substring(with: m.range(at: 1)).lowercased()
                let value = ns.substring(with: m.range(at: 2))
                if kind == "title" { if let t = sanitisedTitle(value) { title = t } }
                else { let t = sanitisedTags(value); if !t.isEmpty { tags = t } }
            } else {
                kept.append(line)
            }
        }
        guard removed else { return Extracted(body: text, title: nil, tags: []) }
        var body = kept.joined(separator: "\n")
        // The lines sat at the very end: drop the blank run they leave behind.
        while let last = body.unicodeScalars.last, CharacterSet.whitespacesAndNewlines.contains(last) {
            body.unicodeScalars.removeLast()
        }
        if text.hasSuffix("\n") { body += "\n" }
        return Extracted(body: body, title: title, tags: tags)
    }

    // MARK: Sanitising

    /// A title safe for a file name and a YAML scalar: single line, no path separators
    /// or control characters, markdown decoration and placeholder text removed, at most
    /// `maxTitleChars` (cut at a word boundary). nil when nothing usable is left.
    public static func sanitisedTitle(_ raw: String) -> String? {
        var t = raw.replacingOccurrences(of: #"[/\\:]"#, with: " - ", options: .regularExpression)
        t = t.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined()
        t = TranscriptCleaner.normaliseSpace(t)
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`*_#<>“”‘’ "))
        if t.hasPrefix("- ") { t = String(t.dropFirst(2)) }
        if t.hasSuffix(" -") { t = String(t.dropLast(2)) }
        if t.count > maxTitleChars {
            let cut = String(t.prefix(maxTitleChars))
            t = (cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? cut)
        }
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: " .,;:-"))
        // The model echoing the instruction placeholder is not a title.
        if t.isEmpty || t.lowercased().hasPrefix("a specific title") { return nil }
        return t
    }

    /// Up to `maxTags` Obsidian-safe slugs from a comma / semicolon / newline separated list.
    public static func sanitisedTags(_ raw: String) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for piece in raw.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\n" }) {
            guard let tag = slug(String(piece)), seen.insert(tag).inserted else { continue }
            out.append(tag)
            if out.count == maxTags { break }
        }
        // A placeholder echo ("3 to 6 lowercase topic keywords...") is not tags.
        if out.contains(where: { $0.contains("lowercase-topic") }) { return [] }
        return out
    }

    /// An Obsidian-safe tag: lowercase letters/digits/`_`/`-`/`/` (Unicode letters kept),
    /// no spaces, no leading `#`, never digits-only (Obsidian rejects those: prefixed `n`),
    /// at most 40 characters. nil for nothing usable.
    public static func slug(_ raw: String) -> String? {
        var s = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "# \t\n\r"))
        s = s.unicodeScalars.map { u -> String in
            let ok = CharacterSet.letters.contains(u) || CharacterSet.decimalDigits.contains(u)
                || CharacterSet.nonBaseCharacters.contains(u) || u == "_" || u == "-" || u == "/"
            return ok ? String(u) : "-"
        }.joined()
        s = s.replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
            .replacingOccurrences(of: "/+", with: "/", options: .regularExpression)
            .replacingOccurrences(of: "-?/-?", with: "/", options: .regularExpression)
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "-/"))
        if s.count > 40 { s = String(s.prefix(40)).trimmingCharacters(in: CharacterSet(charactersIn: "-/")) }
        if s.isEmpty { return nil }
        if s.unicodeScalars.allSatisfy({ CharacterSet.decimalDigits.contains($0) }) { s = "n" + s }
        return s
    }
}
