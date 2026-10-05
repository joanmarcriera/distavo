import Foundation

// Summary templates per meeting type (Vikunja #2940).
//
// A template swaps the SECTION LIST of the prompt (the part that starts at
// "Return the output in Markdown using exactly these sections:") and nothing
// else: the owner/speaker rules, the participants block, the note-language rule
// (#2956), the facts ledger of the facts-first style and the recording metadata
// all keep coming from `Prompt`'s existing templates. With no template chosen
// `Prompt.build` is byte-identical to before (`PromptTests`/`SummaryTemplateTests`).
//
// Templates are written as a small Markdown outline - the same text format the
// user types into Settings for their own template:
//
//     Optional guidance for the model (everything before the first "## ").
//
//     ## Section heading
//     What the section should contain; may include a table.
//
//     ## Next section
//
// Headings are kept EXACTLY as written (English, whatever the note language),
// because `SummaryPostProcess` / `EndOfTurnBlock` key on them.
//
// Resolution order for a recording (`SummaryTemplateCatalog.resolve`):
//   per-recording sidecar  >  folder map (longest subfolder prefix)  >  global setting  >  none.
// The first level that names a template wins; an unknown id there means "none"
// (never an error - a recording is never failed over a template).

/// One note layout: a name, optional guidance and an ordered list of sections.
public struct SummaryTemplate: Equatable, Sendable, Identifiable {

    public struct Section: Equatable, Sendable {
        /// The full heading line, e.g. "## Blockers".
        public var heading: String
        /// What the section should contain (may be multi-line, may hold a table); "" = none.
        public var instruction: String
        public init(heading: String, instruction: String = "") {
            self.heading = heading; self.instruction = instruction
        }
    }

    public var id: String
    public var name: String
    /// One line for pickers and help text.
    public var summary: String
    /// Sentence(s) telling the model what kind of meeting this is; "" = none.
    public var guidance: String
    public var sections: [Section]

    public init(id: String, name: String, summary: String = "", guidance: String = "",
                sections: [Section]) {
        self.id = id; self.name = name; self.summary = summary
        self.guidance = guidance; self.sections = sections
    }

    /// The `## ` heading lines, in order.
    public var headings: [String] { sections.map(\.heading) }

    // MARK: Parsing the outline format

    /// Longest custom template text accepted (characters); longer input is cut so
    /// a pasted document cannot eat the on-device model's 4096-token window.
    public static let maxCustomCharacters = 4000
    /// Most sections accepted from one outline.
    public static let maxSections = 30

    /// Parse the outline format. Returns nil when there is no `## ` heading at
    /// all (nothing to ask the model for). A leading `# Title` line is ignored.
    public static func parse(id: String, name: String, summary: String = "",
                             outline: String) -> SummaryTemplate? {
        var text = String(outline.prefix(maxCustomCharacters))
        // `Prompt.build` substitutes {transcript_text}, {note_owner}, ... AFTER the
        // template is spliced in. Removing every brace (not just the known tokens:
        // one pass can reassemble "{transc{x}ript_text}") means user text can never
        // pull the transcript in twice.
        text = text.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")

        var guidance: [String] = []
        var sections: [Section] = []
        var heading: String?
        var body: [String] = []

        func flush() {
            if let h = heading {
                sections.append(Section(heading: h, instruction: trimmedJoin(body)))
            }
            body = []
        }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r"))
            if line.hasPrefix("## ") {
                flush()
                let title = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                heading = title.isEmpty ? nil : "## " + title
            } else if line.hasPrefix("# ") && !line.hasPrefix("## ") && heading == nil {
                continue                                   // the note title is fixed: "# Meeting notes"
            } else if heading == nil {
                guidance.append(line)
            } else {
                body.append(line)
            }
        }
        flush()
        // A heading listed twice (any case) would be requested twice: keep the first.
        var seen = Set<String>()
        sections = sections.filter { seen.insert($0.heading.lowercased()).inserted }
        guard !sections.isEmpty else { return nil }
        return SummaryTemplate(
            id: id, name: name, summary: summary, guidance: trimmedJoin(guidance),
            sections: Array(sections.prefix(maxSections)))
    }

    private static func trimmedJoin(_ lines: [String]) -> String {
        var l = lines
        while let f = l.first, f.isEmpty { l.removeFirst() }
        while let b = l.last, b.isEmpty { l.removeLast() }
        return l.joined(separator: "\n")
    }

    /// The template written back as the outline text `parse` reads (used by
    /// Settings' "start from a bundled template" for the custom editor).
    public var outline: String {
        var out = guidance.isEmpty ? "" : guidance + "\n\n"
        for s in sections {
            out += s.heading + "\n"
            if !s.instruction.isEmpty { out += s.instruction + "\n" }
            out += "\n"
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    // MARK: Splicing into a prompt

    /// Headings facts-first always opens the note with; a template that lists one
    /// of them must not repeat it.
    static let factsWorkingHeadings = ["## speakers", "## facts ledger"]

    /// The sections actually asked for under `style`: for facts-first, those that
    /// are not already one of its two working sections (case-insensitive).
    func effectiveSections(for style: Prompt.Style) -> [Section] {
        style == .factsFirst
            ? sections.filter { !Self.factsWorkingHeadings.contains($0.heading.lowercased()) }
            : sections
    }

    /// The sections block that replaces the style's own section list.
    func sectionsBlock(for style: Prompt.Style) -> String {
        var out = ""
        for s in effectiveSections(for: style) {
            out += s.heading + "\n\n"
            if !s.instruction.isEmpty { out += s.instruction + "\n\n" }
        }
        return out
    }

    /// Rewrites `base` (a style's raw template text, placeholders still in it)
    /// so that it asks for this template's sections. If the markers are not
    /// found the text is returned unchanged (guarded by tests, so a future prompt
    /// edit that breaks the splice fails loudly in CI rather than silently
    /// dropping the template).
    func apply(to base: String, style: Prompt.Style) -> String {
        let facts = style == .factsFirst
        let startMarker = facts
            ? "Return Markdown using exactly these sections:"
            : "Return the output in Markdown using exactly these sections:"
        guard let start = base.range(of: startMarker),
              let end = base.range(of: "Transcript:\n\n{transcript_text}", range: start.upperBound..<base.endIndex)
        else { return base }

        var text = base
        // Rules that talk about sections only the stock layout has.
        let have = Set(headings.map { $0.dropFirst(3).lowercased() })
        func dropRule(startingWith prefix: String, unless heading: String...) {
            if heading.contains(where: { have.contains($0) }) { return }
            text = text.components(separatedBy: "\n")
                .filter { !$0.hasPrefix(prefix) }.joined(separator: "\n")
        }
        dropRule(startingWith: "- The \"Possible transcription corrections\" section",
                 unless: "possible transcription corrections")
        dropRule(startingWith: "- The \"Highest-ROI follow-up\" and",
                 unless: "highest-roi follow-up", "30-minute post-meeting plan")
        dropRule(startingWith: "- The suggested email is written BY",
                 unless: "suggested follow-up email")
        if facts {
            text = text.replacingOccurrences(
                of: "if the ledger has a rate, the commercial section states it; if it has a start date or an availability date, the timeline states it with who said it.",
                with: "every ledger fact that belongs in one of the sections below is stated there, with who said it.")
        }

        guard let s = text.range(of: startMarker),
              let e = text.range(of: "Transcript:\n\n{transcript_text}", range: s.upperBound..<text.endIndex)
        else { return base }
        var head = ""
        let g = guidance.trimmingCharacters(in: .whitespacesAndNewlines)
        if !g.isEmpty { head = "Meeting type - \(name): \(g)\n\n" }
        let working = facts ? "## Speakers\n\n## Facts ledger\n\n" : ""
        let replacement = head + startMarker + "\n\n# Meeting notes\n\n" + working + sectionsBlock(for: style)
        text.replaceSubrange(s.lowerBound..<e.lowerBound, with: replacement)
        return text
    }
}

// MARK: - Catalog

/// The bundled templates plus the user's own, and the resolution rules.
/// Public surface used by Settings, the recorder and "regenerate with template" (#2947).
public enum SummaryTemplateCatalog {

    /// Id of the user-editable template (its text lives in `summarise.custom_template`).
    public static let customID = "custom"
    /// Stored in a sidecar / folder map to mean "no template, whatever the defaults say".
    public static let noneID = "none"

    private static func bundled(_ id: String, _ name: String, _ summary: String, _ outline: String) -> SummaryTemplate {
        // The bundled outlines are constants; a parse failure is a programming error caught by tests.
        SummaryTemplate.parse(id: id, name: name, summary: summary, outline: outline)!
    }

    /// Stand-up, 1:1, interview, sales call, lecture - in picker order.
    public static let bundledTemplates: [SummaryTemplate] = [
        bundled("standup", "Stand-up", "Per-person updates, plans and blockers.", """
        This is a stand-up or daily sync. Keep it brief: one or two lines per person, no narrative.

        ## Updates by person
        One bullet per person: what they did since the last stand-up.

        ## Plans for today
        One bullet per person: what they said they will do next.

        ## Blockers
        Anything blocking progress, who is blocked and who can unblock it. Write "none stated" if there are none.

        ## Action items
        Use this table:

        | Action | Owner | Deadline | Evidence | Confidence |
        |---|---|---|---|---|

        ## Open questions
        """),
        bundled("one_on_one", "1:1", "Topics, feedback, goals and commitments.", """
        This is a one-to-one conversation between two people (manager and report, mentor and mentee, or peers). Be discreet and factual; do not editorialise about either person.

        ## Topics discussed
        One bullet per topic, with the outcome.

        ## Feedback given and received
        Who said what, kept short and specific.

        ## Goals and progress
        Goals, projects or career themes that came up and how they are going.

        ## Commitments
        Use this table:

        | Action | Owner | Deadline | Evidence | Confidence |
        |---|---|---|---|---|

        ## Concerns to follow up

        ## Topics for the next 1:1
        """),
        bundled("interview", "Interview", "Candidate, assessment, concerns and next steps.", """
        This is a job interview. Record what was actually said about the candidate and the role; never invent qualifications and never state a hiring decision the transcript does not contain.

        ## Candidate and role
        Who the candidate is and which role the interview was for, as stated.

        ## Experience and background

        ## Technical assessment
        Questions asked and how each was answered, with a short excerpt as evidence.

        ## Communication and behavioural signals

        ## Strengths

        ## Concerns

        ## Questions the candidate asked

        ## Next steps and timeline
        Use this table:

        | Step | Owner | Deadline | Evidence | Confidence |
        |---|---|---|---|---|
        """),
        bundled("sales_call", "Sales call", "Needs, budget, objections and next steps.", """
        This is a sales or discovery call. Separate what the prospect said from what the seller said. Do not invent prices, quantities or commitments.

        ## Prospect and context
        Who the prospect is, their role and why they took the call.

        ## Needs and pain points

        ## Current solution and alternatives

        ## Budget, authority and timeline

        ## Objections and concerns

        ## Pricing and terms discussed

        ## Next steps
        Use this table:

        | Action | Owner | Deadline | Evidence | Confidence |
        |---|---|---|---|---|

        ## Deal risks

        ## Suggested follow-up email
        Written by the seller to the prospect, in a professional but natural tone. Do not make it long.
        """),
        bundled("lecture", "Lecture", "Key concepts, examples, terms and questions.", """
        This is a lecture, talk or seminar. Capture what was taught, in the speaker's own terms, for someone revising later. Do not add material the speaker did not cover.

        ## Topic and speaker

        ## Key concepts
        One bullet per concept, with the speaker's definition or explanation.

        ## Examples and demonstrations

        ## Terms and definitions

        ## Questions raised
        Questions from the audience and the answers given.

        ## References and further reading mentioned
        """),
    ]

    /// The user's template, parsed from `summarise.custom_template`; nil when empty
    /// or without a single "## " heading.
    public static func customTemplate(config: Config) -> SummaryTemplate? {
        SummaryTemplate.parse(id: customID, name: "Custom", summary: "Your own sections.",
                              outline: config.summarise.customTemplate)
    }

    /// Every template that can be applied right now: the bundled ones, then the
    /// custom one when its text is usable.
    public static func all(config: Config) -> [SummaryTemplate] {
        bundledTemplates + [customTemplate(config: config)].compactMap { $0 }
    }

    /// The template with this id, or nil for "", "none", an unknown id, or a
    /// "custom" whose text is empty/unusable.
    public static func template(id: String, config: Config) -> SummaryTemplate? {
        let key = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if key == customID { return customTemplate(config: config) }
        return bundledTemplates.first { $0.id == key }
    }

    // MARK: Folders

    /// The subfolder of `recordingsDir` that holds `path`, as a "/"-joined relative
    /// path ("" for the recordings root or a file outside it).
    public static func folder(of path: URL, in recordingsDir: URL) -> String {
        let root = recordingsDir.standardizedFileURL.path
        let full = path.deletingLastPathComponent().standardizedFileURL.path
        guard full.hasPrefix(root + "/") else { return "" }
        return String(full.dropFirst(root.count + 1))
    }

    private static func components(_ folder: String) -> [String] {
        folder.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }

    /// Longest-prefix match of `folder` against the map's keys (case-insensitive,
    /// matching macOS volumes). nil when no key matches.
    public static func folderTemplateID(folder: String, map: [String: String]) -> String? {
        let target = components(folder)
        var best: (length: Int, key: String, id: String)?
        for (key, id) in map {
            let k = components(key)
            guard !k.isEmpty, k.count <= target.count, Array(target.prefix(k.count)) == k else { continue }
            // Ties (two keys differing only in case) resolve alphabetically so the choice is stable.
            if best == nil || k.count > best!.length
                || (k.count == best!.length && key < best!.key) { best = (k.count, key, id) }
        }
        return best?.id
    }

    /// The template for a recording: sidecar id, else folder map, else global.
    /// The first level that names an id wins; if that id is "none" or unknown the
    /// result is nil (a recording is never failed over a template).
    public static func resolve(config: Config, folder: String = "", sidecarID: String? = nil) -> SummaryTemplate? {
        func named(_ s: String?) -> String? {
            let t = s?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return t.isEmpty ? nil : t
        }
        let chosen = named(sidecarID)
            ?? named(folderTemplateID(folder: folder, map: config.summarise.folderTemplates))
            ?? named(config.summarise.template)
        guard let id = chosen else { return nil }
        return template(id: id, config: config)
    }
}
