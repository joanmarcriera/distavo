import Foundation

// Did the model write the note in the language that was asked for? (Vikunja #3585)
//
// `summarise.note_language` "auto" / "ca" / "es" used to be a single sentence that replaced
// "Use British English." deep inside a ~3000-word English prompt; llama3.1:8b ignored it and
// wrote an English note for a Catalan meeting while the footer said "Catalan". The prompt now
// carries the instruction first and last (`Prompt.build`); this is the check on the answer.
//
// A small stop-word language identifier for the languages the app has hand-written prompts
// for (Catalan, Spanish) against English. Only prose is looked at: headings, table rows and
// facts-ledger rows (which quote the speakers in the spoken language) are left out. With too
// few words to judge, or for any other requested language, it says nothing - a check that
// cannot tell must not trigger a retry.
public enum NoteLanguageCheck {

    /// Words that, taken together, tell the three languages apart (no word is shared).
    private static let markers: [String: Set<String>] = [
        "ca": ["els", "les", "amb", "això", "però", "també", "molt", "són", "és", "aquest", "aquesta", "aquests",
               "més", "hem", "han", "perquè", "doncs", "sobre", "entre", "després", "cada", "fer", "pot", "poden",
               "dels", "uns", "unes", "seva", "seu", "meva", "nostre", "estat", "ser", "està", "van", "vam"],
        "es": ["los", "las", "con", "esto", "pero", "también", "muy", "son", "este", "esta", "estos", "más",
               "hemos", "porque", "sobre", "entre", "después", "cada", "hacer", "puede", "pueden", "unos", "unas",
               "su", "sus", "nuestro", "estado", "está", "fue", "fueron", "del", "para", "como", "donde", "hay"],
        "en": ["the", "and", "with", "this", "that", "but", "also", "very", "are", "these", "those", "more",
               "have", "because", "about", "between", "after", "each", "can", "their", "our", "was", "were",
               "from", "for", "which", "will", "would", "has", "been", "they", "not", "of", "to", "is"],
    ]
    /// Catalan and Spanish share some of these on purpose (they stay in both lists only if distinctive);
    /// remove the ones present in more than one list so each word votes once.
    private static let distinctive: [String: Set<String>] = {
        var out: [String: Set<String>] = [:]
        for (code, words) in markers {
            let others = markers.filter { $0.key != code }.values.reduce(into: Set<String>()) { $0.formUnion($1) }
            out[code] = words.subtracting(others)
        }
        return out
    }()

    /// Fewer prose marker words than this and the text is not judged.
    static let minimumVotes = 15

    /// The language the prose most likely is ("ca" / "es" / "en"), or nil when it cannot be judged.
    public static func detect(_ text: String) -> String? {
        var votes: [String: Int] = [:]
        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("#") || t.hasPrefix("|") || t.contains(" | ") || t.hasPrefix(">") { continue }
            for word in SummaryValidator.words(from: t) {
                for (code, set) in distinctive where set.contains(word) { votes[code, default: 0] += 1 }
            }
        }
        let total = votes.values.reduce(0, +)
        guard total >= minimumVotes, let best = votes.max(by: { $0.value < $1.value }) else { return nil }
        // A language needs a clear majority; a mixed note is not called wrong.
        return Double(best.value) / Double(total) >= 0.6 ? best.key : nil
    }

    /// True when `requested` is Catalan or Spanish and the prose is detectably another language.
    public static func ignored(requested: String?, in text: String) -> Bool {
        guard let requested, requested == "ca" || requested == "es",
              let found = detect(text) else { return false }
        return found != requested
    }

    private static func name(_ code: String) -> String {
        WhisperLanguageCatalog.language(forCode: code)?.englishName ?? code
    }

    /// Added to the instruction block for the one automatic retry.
    public static func retryInstruction(requested: String) -> String {
        "The previous attempt was written in the wrong language. Write the whole note, every sentence of every section, in \(name(requested)); keep only the section headings in English."
    }

    /// Footer sentence when the retry still came back in the wrong language.
    public static func footerNote(requested: String, text: String) -> String? {
        guard ignored(requested: requested, in: text), let found = detect(text) else { return nil }
        return "Note language: \(name(requested)) (requested) / \(name(found)) (model ignored)"
    }
}
