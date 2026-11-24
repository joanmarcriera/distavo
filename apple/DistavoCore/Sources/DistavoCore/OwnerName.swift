import Foundation

/// The note owner's name as a pinned fact (drive 2026-11-22).
///
/// Before: the prompt said "Decide which speaker label is the note owner ... refer to that speaker by the
/// name they gave for themselves", so a model that mis-heard the owner's name ("Alex", "Adrian", "Katarina"),
/// or took a recording title ("safety learning for acme") for a person, wrote that into every section.
/// The owner's name is already a setting (`note_owner`); this makes it authoritative in the prompt when it is
/// a real personal name, and refuses to pin anything that is not one (the default "Me", a topic word,
/// a speaker label), in which case the prompt stays byte-identical to before.
public enum OwnerName {
    /// Words that are never a person's name here.
    private static let notNames: Set<String> = [
        "me", "i", "myself", "owner", "note owner", "the note owner", "user", "you", "unknown", "none", "n/a",
        "speaker", "recording", "meeting", "learning", "training", "untitled",
    ]
    /// Lower-case name particles allowed inside a name ("de", "van", "i" in Catalan "Riera i Puig").
    private static let particles: Set<String> = [
        "de", "del", "della", "di", "da", "van", "von", "der", "den", "la", "le", "el", "i", "y", "bin", "al", "mac", "o'",
    ]

    /// True for "Marc", "Ana Riera i Puig", "Ana de la Cruz"; false for "", "Me", "unknown",
    /// "learning", "safety learning for acme", "SPEAKER_00", "Meeting 2026-11-18".
    public static func isPersonName(_ raw: String) -> Bool {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 60, !notNames.contains(name.lowercased()) else { return false }
        if name.range(of: "^SPEAKER[_ ]?\\d*$", options: [.regularExpression, .caseInsensitive]) != nil { return false }
        let words = name.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard (1...6).contains(words.count) else { return false }
        var capitalised = 0
        for w in words {
            if w.contains(where: { $0.isNumber }) { return false }
            guard let first = w.first else { return false }
            if first.isUppercase { capitalised += 1; continue }
            // a lower-case word must be a name particle; "learning", "for", "acme" in lower case are not
            if !particles.contains(w.lowercased()) { return false }
        }
        guard capitalised >= 1, notNames.subtracting(["i"]).isDisjoint(with: words.map { $0.lowercased() }) else { return false }
        return true
    }

    /// The prompt block pinning the owner's name, or "" when `owner` is not a personal name.
    public static func promptBlock(_ owner: String) -> String {
        guard isPersonName(owner) else { return "" }
        let name = owner.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        The note owner's name is \(name) (from the user's settings; authoritative). Use exactly this name for the \
        owner in every section, including task owners and the email sign-off. Never take the owner's name from the \
        transcript (speech-to-text spells names differently each time), from a recording title or from a topic word. \

        """
    }
}
