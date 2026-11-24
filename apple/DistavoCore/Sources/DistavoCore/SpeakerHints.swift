import Foundation

/// What the note owner said about the meeting right after the built-in
/// recorder stopped (Vikunja #2182): how many people spoke and who they were.
/// Stored as a small JSON sidecar in the work dir, keyed by the recording's
/// base name, so the recordings folder (possibly a synced iCloud/Drive folder)
/// stays untouched and the sandboxed edition needs no extra folder access.
/// `Pipeline.processOne` reads it: `count` overrides `transcribe.num_speakers`
/// for that recording, `participants` goes into the prompt verbatim.
public struct SpeakerHints: Codable, Equatable {
    /// Number of people who spoke, when the owner said; nil keeps the config.
    public var count: Int?
    /// Free text, e.g. "Edward (Cambridge University) — interviewer; Marc (me) — interviewee".
    public var participants: String?
    /// Names and jargon for THIS meeting (Vikunja #3584), comma/newline separated terms as typed in
    /// the recorder question. They go to the transcriber and the summary prompt ahead of the global
    /// vocabulary, for this recording only.
    public var terms: [String]?
    /// How the meeting was captured: `SpeakerHints.inPersonCapture` for an in-person meeting recorded on
    /// the microphone alone (Vikunja #3586), nil for a normal call recording.
    public var capture: String?
    public static let inPersonCapture = "in_person"

    public init(count: Int? = nil, participants: String? = nil, terms: [String]? = nil, capture: String? = nil) {
        self.count = count
        self.participants = participants
        self.terms = terms
        self.capture = capture
    }

    /// Names worth giving the transcriber as spelling hints, taken from the participants line
    /// (Vikunja #3950): "Bong Cha (Lightning AI) - interviewer, Annika for WWT" gives
    /// ["Bong Cha", "Lightning AI", "Annika"]. A parenthesised company is kept as its own term; a role
    /// after a dash or "for" is dropped; anything longer than four words is a description, not a name.
    /// They ride the glossary, which the prompt already frames as a spelling aid and never as facts.
    public var participantTerms: [String] {
        guard var text = participants else { return [] }
        // The stored line is "[Owner (me): role. ][In-person …. ]Other participants: <list>": only the list.
        if let marker = text.range(of: "Other participants:", options: .caseInsensitive) { text = String(text[marker.upperBound...]) }
        var terms: [String] = []
        for raw in Self.items(text) {
            var piece = String(raw)
            if let open = piece.firstIndex(of: "("), let close = piece[open...].firstIndex(of: ")") {
                // "(CEO, Acme Ltd)": the role before the comma is not a term.
                let innerParts = piece[piece.index(after: open)..<close].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                if innerParts.count > 1 {
                    let kept = innerParts.filter { !Self.isRole($0) }.joined(separator: ", ")
                    piece.replaceSubrange(piece.index(after: open)..<close, with: kept)
                }
            }
            if let open = piece.firstIndex(of: "("), let close = piece[open...].firstIndex(of: ")") {
                // "(accountant for Example Ltd)", "(CEO of Acme)", "(accountant at X)": a role is not a name, only
                // the organisation after the joining word is. Only split when what precedes it is a role, so
                // "Centre for Computational Biology" and "Bank of England" stay whole.
                var inner = String(piece[piece.index(after: open)..<close])
                for joiner in [" for ", " of ", " at "] {
                    if let r = inner.range(of: joiner, options: .caseInsensitive),
                       Self.isRole(String(inner[..<r.lowerBound])) {
                        inner = String(inner[r.upperBound...])
                        break
                    }
                }
                if !inner.trimmingCharacters(in: .whitespaces).isEmpty, !Self.isRole(inner) { terms.append(inner) }
                piece.removeSubrange(open...close)
            }
            for sep in [" \u{2014} ", " \u{2013} ", " - ", " for "] {
                if let r = piece.range(of: sep) { piece = String(piece[..<r.lowerBound]) }
            }
            terms.append(piece)
        }
        return Vocabulary.normalisedTerms(terms).filter {
            $0.count >= 2 && $0.split(separator: " ").count <= 4 && $0.lowercased() != "me"
        }
    }

    /// A role description ("accountant", "the CFO", "CEO"): a pack trigger word or a phrase opening with a role word.
    private static func isRole(_ text: String) -> Bool {
        if RoleTermPacks.isRoleWord(text) { return true }
        let first = text.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map { $0.lowercased() } ?? ""
        return roleWords.contains(first)
    }

    /// True when there is nothing worth passing on.
    public var isEmpty: Bool {
        (count ?? 0) <= 0 && (participants?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
            && Vocabulary.normalisedTerms(terms ?? []).isEmpty && (capture ?? "").isEmpty
    }

    public static func url(workDir: URL, base: String) -> URL {
        workDir.appendingPathComponent("\(base).speakers.json")
    }

    public static func load(workDir: URL, base: String) -> SpeakerHints? {
        guard let data = try? Data(contentsOf: url(workDir: workDir, base: base)) else { return nil }
        return try? JSONDecoder().decode(SpeakerHints.self, from: data)
    }

    /// The hints for a recording: the work-dir sidecar the recorder's question writes, else a
    /// `<name>.speakers.json` the user put NEXT TO a dropped file (Vikunja #4012; same schema).
    /// The work-dir copy always wins, so an answered sheet is never overridden by a stray file.
    public static func load(workDir: URL, base: String, source: URL) -> SpeakerHints? {
        if let own = load(workDir: workDir, base: base) { return own }
        let beside = source.deletingPathExtension().appendingPathExtension("speakers.json")
        guard let data = try? Data(contentsOf: beside),
              let hints = try? JSONDecoder().decode(SpeakerHints.self, from: data), !hints.isEmpty
        else { return nil }
        return hints
    }

    public func save(workDir: URL, base: String) throws {
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.url(workDir: workDir, base: base), options: .atomic)
    }

    // MARK: Speaker count from the participants text (Vikunja #3580)

    /// Words that start a role or an organisation description, not a person's name: "CEO de acme.com".
    private static let roleWords: Set<String> = [
        "ceo", "cto", "cfo", "coo", "cio", "ciso", "vp", "director", "deputy", "senior", "junior", "head",
        "manager", "lead", "founder", "owner", "partner", "consultant", "consultor", "consultora", "the",
        "una", "un", "el", "la", "from", "de", "del", "who", "which", "that", "empresa", "company",
    ]

    /// How many people the participants text lists: the people named after "Other participants:"
    /// plus the note owner. nil when the text has no such list (nothing to derive a count from).
    ///
    /// A person is a comma/semicolon/newline separated item (commas inside parentheses stay with
    /// their item: "A (CEO, acme), B") that starts with a capitalised word that is not a role word.
    /// It is a SUGGESTION for pre-filling the count and for a warning, never an override the
    /// user cannot change, so the heuristic errs on the side of under-counting descriptions.
    public static func suggestedCount(_ participants: String?) -> Int? { countedPeople(participants) }

    /// A participants list cut into its items: at commas, semicolons and line breaks outside parentheses
    /// ("A (CEO, Acme), B" is two items).
    /// Windows ("\r\n", one Character in Swift) and old Mac line ends as "\n", so a pasted list splits at them.
    static func unixLines(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    static func items(_ text: String) -> [String] {
        var items: [String] = [], depth = 0, current = ""
        for ch in unixLines(text) {
            if ch == "(" { depth += 1 } else if ch == ")" { depth = max(0, depth - 1) }
            if depth == 0 && (ch == "," || ch == ";" || ch == "\n") { items.append(current); current = "" }
            else { current.append(ch) }
        }
        items.append(current)
        return items
    }

    /// A list item starts a person when its first word starts with a capital, or with a letter of a script
    /// that has no capitals (Hebrew, Thai, Chinese…), and is not a role word.
    static func startsWithAName(_ item: String) -> Bool {
        guard let first = item.split(whereSeparator: { $0.isWhitespace || $0 == "(" }).first, let ch = first.first,
              ch.isUppercase || (ch.isLetter && !ch.isLowercase) else { return false }
        return !roleWords.contains(first.lowercased())
    }

    /// The count the stop question pre-fills from the participants text. Only a list the OWNER gave for this
    /// recording (typed, picked, or typed in Quick Notes) counts: a list that is merely suggested from an
    /// earlier meeting or the calendar and left untouched pre-fills nothing, so the count stays automatic.
    /// A left-over "one other person" once forced 2 speakers on a six-person call and merged everyone.
    public static func prefilledCount(participants: String?, ownerGaveTheList: Bool) -> Int? {
        ownerGaveTheList ? countedPeople(participants) : nil
    }

    static func countedPeople(_ participants: String?) -> Int? {
        guard let text = participants.map(unixLines),
              let marker = text.range(of: "Other participants:", options: .caseInsensitive) else { return nil }
        let items = Self.items(String(text[marker.upperBound...]))
        // "Anna and Pere" / "Anna & Pere" are two people (outside parentheses: "Marks & Spencer" in brackets stays).
        var people = 0
        for item in items {
            let parts = joinedPeople(item)
            people += parts.count > 1 ? parts.count : (startsWithAName(item.trimmingCharacters(in: .whitespacesAndNewlines)) ? 1 : 0)
        }
        return people == 0 ? nil : people + 1
    }

    /// One list item as the people it joins: "Anna and Pere" -> ["Anna", "Pere"]. An item that is one person,
    /// or whose parts do not ALL start a name ("Research and development"), comes back whole.
    static func joinedPeople(_ item: String) -> [String] {
        var parts: [String] = [], depth = 0, current = ""
        let words = item.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        for (n, w) in words.enumerated() {
            depth += w.filter { $0 == "(" }.count
            // "y", "i", "e" join only as typed in lower case: "Anna E Smith" and "Joan I Puig" have a middle initial.
            var joins = depth == 0 && (["and", "&"].contains(w.lowercased()) || ["y", "i", "e"].contains(w))
            // "Josep Puig i Cadafalch", "Santiago Ramón y Cajal": a full name, then y/i/e and ONE more word
            // is a compound surname, not a second person ("Anna i Pere" and "Anna Puig i Pere Soler" are two).
            if joins, ["y", "i", "e"].contains(w.lowercased()), current.split(separator: " ").count >= 2 {
                // The surname ends where the company or the role starts ("… y Cajal from Acme", "… i Cadafalch - architect").
                var rest: [String] = []
                for word in words[(n + 1)...] {
                    if ["and", "&", "y", "i", "e", "from", "at", "for", "-", "–", "—"].contains(word.lowercased()) || word.hasPrefix("(") { break }
                    rest.append(word)
                    if word.hasSuffix(":") { break }
                }
                if rest.filter({ !$0.isEmpty && !$0.hasPrefix("(") }).count == 1 { joins = false }
            }
            if joins { parts.append(current); current = "" }
            else { current += (current.isEmpty ? "" : " ") + w }
            depth = max(0, depth - w.filter { $0 == ")" }.count)
        }
        parts.append(current)
        let trimmed = parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        // A joined part counts only when BOTH sides start a name ("Anna and Pere", not "Research and Development").
        return trimmed.count > 1 && trimmed.allSatisfy(startsWithAName) ? trimmed : [item]
    }

    /// The speaker count to give the diarizer (Vikunja #3953). The owner's explicit count wins. Without
    /// one, a participants list naming more people than the configured count raises it, because forcing
    /// 2 on a 3-person call merges two voices into one turn; it never lowers a configured count, and
    /// 0 (auto) stays auto. Result 0 = auto.
    public static func reconciledCount(hintCount: Int?, participants: String?, configured: Int) -> Int {
        if let c = hintCount, c > 0 { return c }
        if configured > 0, let listed = suggestedCount(participants), listed > configured { return listed }
        return configured
    }

    /// Lowercased first names (first word of each listed person) in a participants text, or [] when none.
    /// Same item splitting and role-word filter as `suggestedCount`; used to tell whether two meetings
    /// had different people (Vikunja #3584). Falls back to the whole text when there is no
    /// "Other participants:" marker.
    public static func listedNames(_ participants: String?) -> Set<String> {
        guard let text = participants.map(unixLines), !text.isEmpty else { return [] }
        let body = text.range(of: "Other participants:", options: .caseInsensitive).map { text[$0.upperBound...] } ?? text[...]
        let items = Self.items(String(body))
        var names = Set<String>()
        for item in items {
            guard let first = item.split(whereSeparator: { $0.isWhitespace || $0 == "(" }).first,
                  first.first?.isUppercase == true, !roleWords.contains(first.lowercased()) else { continue }
            names.insert(first.lowercased())
        }
        return names
    }

    /// "4 people listed but 2 speakers set", or nil when they agree, no count is set (auto), or the
    /// text lists nobody. Shown inline in the recorder's question and logged.
    public static func mismatchWarning(count: Int?, participants: String?) -> String? {
        guard let count, count > 0, let listed = suggestedCount(participants), listed != count else { return nil }
        return "\(listed) \(listed == 1 ? "person" : "people") listed but \(count) \(count == 1 ? "speaker" : "speakers") set"
    }
}
