import Foundation

/// Action items carry an owner only when the transcript names one (drive 2026-11-23).
///
/// With `summarise.action_items` the Tasks section writes `- [ ] <task> — owner: <name or unassigned>; due: ...`.
/// A model fills the owner with a plausible name from its own guess. This post-check keeps an owner that is
///  - "unassigned" (or empty / none),
///  - the configured note owner (full name or any word of it, 3+ letters: people rarely say their own name),
///  - a name from the participants line the owner typed (those people were there),
///  - heard in the transcript (a whole name, or any word of it, 3+ letters; case and accents ignored),
///  - or a name in the user's names glossary (`NameGlossary`) when the entry, or any spelling of it, is heard.
/// Any other owner becomes `unassigned`. Pure; the footer reports the count.
public enum ActionItemOwners {
    public struct Result: Equatable, Sendable { public var text: String; public var cleared: Int }

    private static let unassigned: Set<String> = ["unassigned", "none", "n/a", "nobody", "unknown", "tbd", ""]

    public static func check(_ note: String, transcript: String, noteOwner: String,
                             participants: String? = nil, glossary: NameGlossary = NameGlossary()) -> Result {
        let heard = fold(transcript)
        var known: Set<String> = Set(words(noteOwner).map(fold))
        if OwnerIdentity.isConfigured(noteOwner) { known.insert(fold(TranscriptCleaner.normaliseSpace(noteOwner))) }
        for w in words(participants ?? "") { known.insert(fold(w)) }
        // Glossary entries whose name or any spelling is heard: the model may have written either form.
        for e in glossary.entries where ([e.canonical] + e.aliases).contains(where: { named($0, in: heard) }) {
            for n in [e.canonical] + e.aliases { known.insert(fold(n)); words(n).forEach { known.insert(fold($0)) } }
        }
        var cleared = 0
        let lines = note.components(separatedBy: "\n").map { line -> String in
            guard line.trimmingCharacters(in: .whitespaces).hasPrefix("- ["),
                  let r = line.range(of: "owner:", options: [.caseInsensitive, .backwards]) else { return line }
            let after = line[r.upperBound...]
            let end = after.firstIndex(of: ";") ?? after.endIndex
            let owner = after[..<end].trimmingCharacters(in: .whitespaces)
            let f = fold(owner)
            let nameWords = namedWords(owner)   // capitalised words only: "the client" or "Finance team" are not names
            if unassigned.contains(f) || known.contains(f) || nameWords.contains(where: { known.contains(fold($0)) }) { return line }
            if named(owner, in: heard) { return line }
            cleared += 1
            return String(line[..<r.upperBound]) + " unassigned" + String(after[end...])
        }
        return Result(text: lines.joined(separator: "\n"), cleared: cleared)
    }

    /// Lower-case, accents removed.
    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Capitalised words of 3+ letters of an owner text (what the name of a person looks like).
    private static func namedWords(_ s: String) -> [String] { words(s).filter { $0.first?.isUppercase == true } }

    /// Words of 3+ letters.
    private static func words(_ s: String) -> [String] {
        s.split(whereSeparator: { !$0.isLetter }).map(String.init).filter { $0.count >= 3 }
    }

    /// True when the whole owner text, or any single word of it (3+ letters), occurs as a whole word in `heard` (already folded).
    private static func named(_ owner: String, in heard: String) -> Bool {
        let candidates = (owner.first?.isUppercase == true ? [fold(owner)] : []) + namedWords(owner).map(fold)
        return candidates.contains { c in
            guard !c.isEmpty, let re = try? NSRegularExpression(
                pattern: "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: c) + "(?![\\p{L}\\p{N}])")
            else { return false }
            return re.firstMatch(in: heard, range: NSRange(location: 0, length: (heard as NSString).length)) != nil
        }
    }

    public static func note(cleared: Int) -> String? {
        cleared > 0 ? "\(cleared) task owner\(cleared == 1 ? "" : "s") not named in the transcript set to unassigned" : nil
    }
}
