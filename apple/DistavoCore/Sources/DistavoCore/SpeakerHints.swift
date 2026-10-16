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
    public static func suggestedCount(_ participants: String?) -> Int? {
        guard let text = participants,
              let marker = text.range(of: "Other participants:", options: .caseInsensitive) else { return nil }
        var items: [String] = []
        var depth = 0
        var current = ""
        for ch in text[marker.upperBound...] {
            if ch == "(" { depth += 1 } else if ch == ")" { depth = max(0, depth - 1) }
            if depth == 0 && (ch == "," || ch == ";" || ch == "\n") { items.append(current); current = "" }
            else { current.append(ch) }
        }
        items.append(current)
        let people = items.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { item in
            guard let first = item.split(whereSeparator: { $0.isWhitespace || $0 == "(" }).first,
                  first.first?.isUppercase == true else { return false }
            return !roleWords.contains(first.lowercased())
        }
        return people.isEmpty ? nil : people.count + 1
    }

    /// "4 people listed but 2 speakers set", or nil when they agree, no count is set (auto), or the
    /// text lists nobody. Shown inline in the recorder's question and logged.
    public static func mismatchWarning(count: Int?, participants: String?) -> String? {
        guard let count, count > 0, let listed = suggestedCount(participants), listed != count else { return nil }
        return "\(listed) \(listed == 1 ? "person" : "people") listed but \(count) \(count == 1 ? "speaker" : "speakers") set"
    }
}
