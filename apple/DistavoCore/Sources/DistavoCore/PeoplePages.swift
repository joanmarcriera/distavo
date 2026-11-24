// PeoplePages.swift — one Markdown page per person the owner talks with (drive 2026-11-23, people directory step 1).
//
// `notes/people/<Name>.md` for every person the OWNER named, plus `notes/people/_People.md` (an index, most
// recently seen first). A person comes only from what the owner confirmed, never from a name the model guessed:
//   - a speaker renamed in the Notes window (`<base>.speaker-names.json`): they SPOKE in that meeting;
//   - the "who was in this meeting?" answer (`<base>.speakers.json` participants): they were LISTED, and a
//     "(Organisation)" or " - role" typed there seeds the page when its field is still empty.
// Spellings merge through the page's own `aliases:` and through `names.txt` (`NameGlossary`).
//
// The page belongs to the owner. Distavo writes the whole page only when it creates it; afterwards it rewrites
// only the block between the two `distavo:meetings` markers and fills `role:` / `organisation:` when they are
// empty. Everything else (role, organisation, LinkedIn link, aliases, free notes) is never changed. To merge two
// people: menu "Merge People…" (`PeopleMerge`), which adds the other spelling to `aliases:` and sets the other
// page aside so the merge can be undone.
//
// LinkedIn: `linkedin:` is typed or pasted by the owner. While it is empty the page carries a search link that
// opens LinkedIn's own people search in the owner's browser; Distavo itself never contacts LinkedIn.
//
// Nothing here runs automatically: the app calls `update` from the menu ("Update People Pages"). The subfolder
// keeps the pages out of the Notes window and the search index (their listings do not recurse). Same notes and
// sidecars in, same bytes out (no clock in a page). Pure apart from `update`.

import Foundation

public enum PeoplePages {
    public static let folderName = "people"
    public static let indexName = "_People.md"
    /// The same people grouped by the organisation their page names (idea 10: the network view).
    public static let organisationsName = "_Organisations.md"
    public static let blockStart = "<!-- distavo:meetings:start (rewritten by Distavo; write your own notes above) -->"
    public static let blockEnd = "<!-- distavo:meetings:end -->"

    /// One confirmed appearance of a person in a meeting.
    public struct Meeting: Equatable, Sendable {
        public var base: String
        public var date: Date
        public var title: String
        public var notePath: URL
        /// true = a renamed speaker (they spoke); false = only listed in the participants answer.
        public var spoke: Bool
        /// The name came from voice recognition and the owner has not confirmed it for this meeting.
        public var byVoice = false
        /// What they said about their job early in that meeting ("head of platform, Acme"; `SelfIntroductions.said`).
        public var said: String?
    }

    public struct Person: Equatable, Sendable {
        public var name: String
        public var aliases: [String] = []
        /// From the participants answer, else from what they said themselves in their most recent meeting;
        /// only ever used to fill an empty field of the page.
        public var role: String?
        public var organisation: String?
        public var meetings: [Meeting] = []
        /// Working storage of `collect` (empty in what it returns).
        var statements: [(Date, SelfIntroductions.Said?)] = []

        public static func == (a: Person, b: Person) -> Bool {
            a.name == b.name && a.aliases == b.aliases && a.role == b.role && a.organisation == b.organisation && a.meetings == b.meetings
        }
    }

    public struct Summary: Equatable, Sendable {
        public var created: [String] = []
        public var updated: [String] = []
        public var unchanged: Int = 0
        /// Files in the people folder that carry a person's name but could not be read as text: left untouched.
        public var unreadable: [String] = []
        public var index: URL
    }

    public static func folder(notesDir: URL) -> URL {
        notesDir.appendingPathComponent(folderName, isDirectory: true)
    }

    // MARK: Participants line

    /// "Edward (Cambridge University) - interviewer; Annika for WWT, Marc (me)" ->
    /// [Edward / Cambridge University / interviewer, Annika / WWT]. The owner's own entry ("(me)") and anything
    /// that is not a short capitalised name (a description such as "two engineers") is left out.
    public static func parseParticipants(_ text: String) -> [(name: String, organisation: String?, role: String?)] {
        var out: [(name: String, organisation: String?, role: String?)] = []
        // The stored line is "[Owner (me): role. ][In-person meeting …. ]Other participants: <list>": only the
        // list names other people.
        var text = text
        if let marker = text.range(of: "Other participants:", options: .caseInsensitive) { text = String(text[marker.upperBound...]) }
        for raw in listItems(text).flatMap(joined) {
            var piece = raw
            var organisation: String?, role: String?
            if let open = piece.firstIndex(of: "(") {
                // "Anna (Acme" (never closed): what follows the bracket is still what the owner typed about Anna.
                let close = piece[open...].firstIndex(of: ")")
                let inner = piece[piece.index(after: open)..<(close ?? piece.endIndex)].trimmingCharacters(in: .whitespaces)
                if let close { piece.removeSubrange(open...close) } else { piece.removeSubrange(open...) }
                if ["me", "jo", "yo", "myself"].contains(inner.lowercased()) { continue }
                var split = false
                // "buyer at Acme", "CTO of Acme" split; "University of Cambridge", "Bank of England" are one name:
                // " of " separates only after a job word.
                for joiner in [" at ", " for ", " of "] {
                    guard let r = inner.range(of: joiner, options: .caseInsensitive) else { continue }
                    let before = String(inner[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                    if joiner == " of ", !before.lowercased().split(separator: " ").contains(where: { SelfIntroductions.roleWords.contains(String($0)) }) { continue }
                    role = before
                    organisation = String(inner[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                    split = true
                    break
                }
                if !split, !inner.isEmpty { organisation = inner }
                // "Anna (Acme) (remote)": a second bracket is not part of the name either.
                piece = piece.replacingOccurrences(of: #"\([^)]*\)?"#, with: " ", options: .regularExpression)
            }
            for dash in [" — ", " – ", " - ", ": "] {
                if let r = piece.range(of: dash) {
                    let after = String(piece[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                    if !after.isEmpty { role = after }
                    piece = String(piece[..<r.lowerBound])
                    break
                }
            }
            for joiner in [" for ", " at ", " from "] {
                guard let r = piece.range(of: joiner, options: .caseInsensitive) else { continue }
                let company = String(piece[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                piece = String(piece[..<r.lowerBound])   // the name ends here whatever else was typed
                guard !company.isEmpty else { break }
                // "Pere at Acme (CTO)": the bracket held the job, not the employer.
                if let inBracket = organisation, role == nil { role = inBracket; organisation = company }
                else if organisation == nil { organisation = company }
                break
            }
            let name = piece.split(separator: " ").joined(separator: " ")
            guard isPersonName(name) else { continue }
            out.append((name, organisation.flatMap { $0.isEmpty ? nil : $0 }, role.flatMap { $0.isEmpty ? nil : $0 }))
        }
        return out
    }

    /// "Anna and Pere from Acme" is two people, and so is "Anna and Pere - sales" (what follows the names belongs
    /// to the last one). Only names are joined: after "from", "at", "for", a dash or a colon comes a company or a
    /// role, whatever it says ("Anna from Marks and Spencer", "Anna - Sales and Marketing").
    static func joined(_ typed: String) -> [String] {
        // "Petra Novak- buyer": the dash glued to the name is the dash before a role.
        let item = typed.replacingOccurrences(of: #"(?<=\p{L})[-–—] (?=\S)"#, with: " - ", options: .regularExpression)
        var depth = 0, cut: String.Index?, company = false
        var i = item.startIndex
        while i < item.endIndex, cut == nil {
            if item[i] == "(" { depth += 1 } else if item[i] == ")" { depth = max(0, depth - 1) }
            if depth == 0 {
                let rest = item[i...]
                if [" from ", " at ", " for "].contains(where: { rest.lowercased().hasPrefix($0) }) { cut = i; company = true }
                else if [" — ", " – ", " - ", ": "].contains(where: { rest.hasPrefix($0) }) { cut = i }
            }
            i = item.index(after: i)
        }
        guard let cut else { return SpeakerHints.joinedPeople(item) }
        let names = SpeakerHints.joinedPeople(String(item[..<cut]))
        var tail = String(item[cut...]), more: [String] = []
        // "Anna from Acme and Pere from Beta": a second person only when what follows the joiner starts a name
        // AND has a company of its own ("Anna from Marks and Spencer" is one person).
        // The second one is introduced by the same word as the first ("from … and Pere from …"), outside brackets:
        // "Anna from Marks and Spencer for the audit" and "(Head of Sales and Marketing for EMEA)" name nobody new.
        let word = tail.dropFirst().prefix { $0 != " " }.lowercased()
        var search = tail.startIndex
        while company, more.isEmpty, let r = tail.range(of: #" (and|&|i|y) (?=\p{Lu})"#, options: .regularExpression, range: search..<tail.endIndex) {
            search = r.upperBound
            let before = tail[..<r.lowerBound]
            guard before.filter({ $0 == "(" }).count <= before.filter({ $0 == ")" }).count else { continue }
            let next = String(tail[r.upperBound...])
            if next.range(of: "^[^()]*? " + NSRegularExpression.escapedPattern(for: word) + #" \S"#, options: [.regularExpression, .caseInsensitive]) != nil,
               !next.contains(" - "), !next.contains(": ") {
                tail = String(before)
                more = joined(next)
            }
        }
        return (names.count > 1 ? names.dropLast() + [names[names.count - 1] + tail] : [String(item[..<cut]) + tail]) + more
    }

    /// The people list cut at commas, semicolons and line ends, except inside a closed pair of brackets
    /// ("Anna (Acme, Inc), Pere" is two people). A bracket that is never closed does not swallow the rest.
    static func listItems(_ text: String) -> [String] {
        var items: [String] = [], current = "", depth = 0
        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            if ch == "(", text[i...].prefix(while: { $0 != "\n" }).contains(")") { depth += 1 }
            else if ch == ")" { depth = max(0, depth - 1) }
            if ch == "\n" { depth = 0 }
            if depth == 0 && (ch == "," || ch == ";" || ch == "\n") { items.append(current); current = "" }
            else { current.append(ch) }
            i = text.index(after: i)
        }
        items.append(current)
        return items.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// A short name starting with a capital letter; never a diariser label or a placeholder.
    public static func isPersonName(_ raw: String) -> Bool {
        // "Anna Puig." typed with a stray full stop is Anna Puig.
        var name = raw
        if name.hasSuffix("."), let last = name.split(separator: " ").last, !isInitialOrTitle(last) { name = String(name.dropLast()) }
        let words = name.split(separator: " ")
        guard !words.isEmpty, words.count <= maxNameWords, name.count <= 60, let first = name.unicodeScalars.first,
              CharacterSet.uppercaseLetters.contains(first) else { return false }
        if name.range(of: #"^(SPEAKER|Speaker)[_ ]?\d+$"#, options: .regularExpression) != nil { return false }
        if name.contains("/") || name.contains("\\") || name.contains("[") || name.contains("]") { return false }
        if name.contains("(") || name.contains(")") || name.contains(",") || name.contains(";") { return false }
        // A capitalised description is not a person: "The CFO", "Someone from procurement", "Two engineers".
        let notAName: Set<String> = ["the", "a", "an", "someone", "somebody", "anyone", "everyone", "two", "three", "four",
                                     "five", "six", "several", "some", "other", "others", "people", "team", "various", "many",
                                     "probably", "possibly", "maybe", "perhaps", "ask", "not", "is", "are", "was", "who"]
        if notAName.contains(words[0].lowercased()) || name.contains(":") { return false }
        // A sentence is not a person ("Not sure. Someone new?", "Anna. Joined late."): a full stop only ends
        // initials or a title ("J. Smith", "J.R.R. Tolkien", "Prof. Puig", "Smith Jr.").
        if name.contains(where: { "?!=<>|*#@{}\"".contains($0) }) { return false }   // also "A => Anna Berg", a note to self
        for w in words where w.contains(".") { guard isInitialOrTitle(w) else { return false } }
        // "Anna - Acme", "Anna's boss".
        if words.contains(where: { $0.hasSuffix("-") || $0.hasPrefix("-") || $0 == "–" || $0 == "—" }) || words.dropLast().contains(where: { $0.hasSuffix("'s") || $0.hasSuffix("’s") }) { return false }
        // Nor is a remark ("He is", "Who he is", "Head of procurement in Vic", "Pere es comercial"): a word of a
        // sentence written in lower case, or several lower-case words that are no part of a surname.
        var lower: [String] = []
        for (i, w) in words.enumerated().dropFirst() where w.first?.isLowercase == true || w.first == "'" || w.first == "’" {
            let l = w.lowercased()
            // "Sophie in 't Veld".
            if l == "in", i + 1 < words.count, ["'t", "’t"].contains(words[i + 1].lowercased()) { continue }
            lower.append(l)
        }
        if lower.contains(where: sentenceWords.contains) { return false }
        func particle(_ w: String) -> Bool {
            nameParticles.contains(w) || ["l'", "l’", "d'", "d’", "al-", "el-"].contains { w.hasPrefix($0) }
        }
        if words.count > 2, lower.filter({ !particle($0) }).count > 2 { return false }
        // A job is not a name ("Sales Director").
        if words.count > 1, SelfIntroductions.roleWords.contains(words.last!.lowercased()) { return false }
        // Two people typed as one ("Anna and Pere" is split before it gets here; this is what is left).
        if words.dropFirst().contains(where: { ["and", "&", "+"].contains($0.lowercased()) }) { return false }
        return !placeholders.contains(name.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".!?- ")))
    }

    /// "J.", "J.R.R.", "Dr.", "Prof.", "Jr.": the only words of a name that hold a full stop.
    static func isInitialOrTitle<S: StringProtocol>(_ word: S) -> Bool {
        if word.range(of: #"^(\p{L}\.){1,4}$"#, options: .regularExpression) != nil { return true }
        guard word.hasSuffix("."), !word.dropLast().contains(".") else { return false }
        return ["dr", "prof", "mr", "mrs", "ms", "sr", "sra", "srta", "jr", "st", "capt", "col", "gen", "rev", "ing", "eng",
                "mme", "mlle", "dra", "don", "sir", "lic", "arq"].contains(word.dropLast().lowercased())
    }

    /// Lower-case words a name may hold ("Maria del Mar", "Jan van der Berg", "Josep Puig i Cadafalch").
    static let nameParticles: Set<String> = ["de", "del", "dels", "la", "las", "los", "el", "i", "y", "e", "van", "von", "der", "den",
                                             "ten", "ter", "te", "op", "'t", "’t", "zu", "zur", "vom", "und", "af", "av", "da", "das", "di", "do", "dos", "du", "des",
                                             "della", "dalla", "dello", "delle", "degli", "dei", "le", "bin", "bint", "ibn", "al", "el-", "st", "st.", "mc", "o'"]
    /// Words of a sentence: written in lower case inside a name, or as its first word, they make it a remark.
    static let sentenceWords: Set<String> = ["is", "are", "was", "were", "who", "whom", "of", "in", "on", "at", "from", "for", "with", "to",
                                             "that", "this", "his", "her", "their", "not", "no", "know", "sure", "maybe", "es", "és", "son", "són",
                                             "que", "qui", "quien", "en", "amb", "con", "per", "por", "para", "sé", "se", "més", "más", "he", "she", "they",
                                             "too", "again", "also", "later", "boss", "colleague", "friend", "wife", "husband"]
    /// "Maria del Mar Bonet Verdaguer" is one person; a longer run of words is a description.
    static let maxNameWords = 6
    /// What people type when there is nobody to name.
    static let placeholders: Set<String> = [
        "unknown", "me", "note owner", "owner", "speaker", "none", "nobody", "no one", "noone", "tbd", "tbc",
        "todo", "myself", "just me", "only me", "same", "same as above", "as above", "unknown speaker", "null",
        "nadie", "ninguno", "ningú", "yo", "", "he", "she", "they", "who", "him", "her", "them"]

    // MARK: Collect

    /// Everyone the owner confirmed, with their meetings (newest first), sorted by name. `known` maps a
    /// lowercased spelling to the name it belongs to (existing pages' names and aliases, then `names.txt`).
    public static func collect(notesDir: URL, workDir: URL, ownerName: String = "",
                               glossary: NameGlossary = NameGlossary(), known: [String: String] = [:],
                               timeZone: TimeZone = .current) -> [Person] {
        var canonical = known
        for e in glossary.entries where isPersonName(e.canonical) {
            let target = canonical[e.canonical.lowercased()] ?? e.canonical
            for s in [e.canonical] + e.aliases where canonical[s.lowercased()] == nil { canonical[s.lowercased()] = target }
        }
        // "Dana Owner." in Settings is still Dana Owner.
        func plain(_ s: String) -> String { s.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".,;"))).lowercased() }
        let owner = plain(ownerName)
        // People who already have a page (`known` holds every page's name and aliases).
        let pagesExist = Set(known.values.map { $0.lowercased() })
        var people: [String: Person] = [:]   // keyed by lowercased name
        var voiceGuesses: [(name: String, entry: NoteEntry)] = []
        func person(_ spelled: String) -> String? {
            let name = canonical[spelled.lowercased()] ?? spelled
            let key = name.lowercased()
            // A page the owner keeps names a person however it is written ("name: anna berg").
            guard isPersonName(name) || pagesExist.contains(key), owner.isEmpty || (plain(name) != owner && plain(spelled) != owner) else { return nil }
            if people[key] == nil { people[key] = Person(name: name) }
            if spelled != name, !people[key]!.aliases.contains(spelled) { people[key]!.aliases.append(spelled) }
            return key
        }
        let entries = NotesLibrary.scan(notesDir: notesDir, workDir: workDir, timeZone: timeZone).filter { !$0.isVariant }
        for e in entries {
            var seen: [String: Bool] = [:]   // person key -> spoke
            var said: [String: SelfIntroductions.Said] = [:]
            if let names = SpeakerNames.load(workDir: workDir, base: e.base) {
                let segments = TranscriptSegments.load(workDir: workDir, base: e.base)?.segments ?? []
                let guessedNames = Set((names.byVoice ?? []).map { $0.lowercased() })
                // A name whose speaker has no part of the transcript left (every part was moved to someone else,
                // or the transcript was reverted to before that speaker existed) did not speak in this meeting.
                // The mapping itself stays: Reset and Revert need it.
                var speaking = Set(segments.compactMap { $0.speaker?.trimmingCharacters(in: .whitespaces).lowercased() })
                // Someone whose words got no times is in the clean transcript only: they spoke too.
                if let clean = try? String(contentsOf: Pipeline.cachedTranscriptURL(workDir: workDir, base: e.base), encoding: .utf8) {
                    for line in clean.components(separatedBy: "\n").map(bare) where line.hasPrefix("[") && line.hasSuffix("]") {
                        speaking.insert(line.dropFirst().dropLast().trimmingCharacters(in: .whitespaces).lowercased())
                    }
                }
                for name in Set(names.names.values) {
                    if !segments.isEmpty, !speaking.contains(name.trimmingCharacters(in: .whitespaces).lowercased()) { continue }
                    // A voice guess is set aside: it never creates a person (see after the loop).
                    if guessedNames.contains(name.lowercased()) { voiceGuesses.append((name, e)); continue }
                    guard let key = person(name.trimmingCharacters(in: .whitespaces)) else { continue }
                    seen[key] = true
                    if let s = SelfIntroductions.said(by: name, in: segments) { said[key] = s }
                }
            }
            if let line = SpeakerHints.load(workDir: workDir, base: e.base)?.participants {
                for p in parseParticipants(line) {
                    guard let key = person(p.name) else { continue }
                    if seen[key] == nil { seen[key] = false }
                    if people[key]!.role == nil { people[key]!.role = p.role }
                    if people[key]!.organisation == nil { people[key]!.organisation = p.organisation }
                }
            }
            for (key, spoke) in seen {
                people[key]!.meetings.append(Meeting(base: e.base, date: e.date, title: e.title, notePath: e.notePath,
                                                     spoke: spoke, said: said[key]?.line))
                people[key]!.statements.append((e.date, said[key]))
            }
        }
        // Voice-recognised appearances: added only to someone the owner confirmed elsewhere or who has a page.
        for (name, e) in voiceGuesses {
            let target = (canonical[name.lowercased()] ?? name).lowercased()
            guard people[target] != nil || pagesExist.contains(target), let key = person(name.trimmingCharacters(in: .whitespaces)) else { continue }
            if let i = people[key]!.meetings.firstIndex(where: { $0.base == e.base }) {
                people[key]!.meetings[i].spoke = true
                people[key]!.meetings[i].byVoice = true
            } else {
                people[key]!.meetings.append(Meeting(base: e.base, date: e.date, title: e.title, notePath: e.notePath,
                                                     spoke: true, byVoice: true))
            }
        }
        return people.values.map { p in
            var p = p
            p.meetings.sort { $0.date != $1.date ? $0.date > $1.date : $0.base < $1.base }
            // What they said themselves fills what the participants answer left empty: the most recent statement.
            for (_, s) in p.statements.sorted(by: { $0.0 > $1.0 }) {
                if p.role == nil { p.role = s?.role }
                if p.organisation == nil { p.organisation = s?.organisation }
            }
            p.statements = []
            p.aliases.sort()
            return p
        }.filter { !$0.meetings.isEmpty }.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    // MARK: Pages

    /// The page's frontmatter as written by the owner: only `key: value` lines between the first two `---`.
    public static func frontmatter(of page: String) -> [String: String] {
        let lines = page.components(separatedBy: "\n").map(bare)
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { return [:] }
        var out: [String: String] = [:]
        var listKey: String?   // "aliases:" with nothing after it, followed by "  - item" lines (Obsidian's form)
        var inBlock = false    // the indented lines of "notes: |" are that key's text, never keys of their own
        for line in lines[1..<end] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if inBlock {
                if line.hasPrefix(" ") || line.hasPrefix("\t") || trimmed.isEmpty { continue }
                inBlock = false
            }
            // A comment line is nobody's value, whatever it holds ("# older spellings: below").
            if trimmed.hasPrefix("#") { continue }
            if let key = listKey, let item = listItem(trimmed) {
                guard !item.isEmpty else { continue }
                // Quoted as `aliases(inFrontmatter:)` reads it back: a nickname keeps its own quotes (Anna "Annie" Berg).
                let quoted = "\"" + item.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
                out[key] = (out[key] ?? "").isEmpty ? quoted : out[key]! + ", " + quoted
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let raw = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if isBlockIndicator(raw) { out[key] = raw; inBlock = true; listKey = nil; continue }
            // "aliases:  # as she signs" has no value of its own.
            out[key] = raw.hasPrefix("#") ? "" : unquote(raw)
            listKey = out[key]!.isEmpty && !line.hasPrefix(" ") ? key : nil
        }
        return out
    }

    /// "|", ">-", "|2", "| # comment": the value is the indented lines that follow.
    static func isBlockIndicator(_ value: String) -> Bool {
        value.range(of: #"^[|>]([1-9]?[+-]?|[+-]?[1-9]?)\s*(#.*)?$"#, options: .regularExpression) != nil
    }

    /// A list line ("- Petra", "-\tPetra", "- Pet  # short", "- \"P #1\"") as its value, "" for a bare "-";
    /// nil when the line is not a list item.
    static func listItem(_ trimmed: String) -> String? {
        guard trimmed == "-" || trimmed.hasPrefix("- ") || trimmed.hasPrefix("-\t") else { return nil }
        var v = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
        if let q = v.first, q == "\"" || q == "'" {
            // A comment can only follow the closing quote.
            if let close = v.dropFirst().lastIndex(of: q), v[v.index(after: close)...].trimmingCharacters(in: .whitespaces).hasPrefix("#") {
                v = String(v[...close])
            }
        } else if let hash = v.range(of: #"(^|\s)#"#, options: .regularExpression) {
            v = String(v[..<hash.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return unquote(v)
    }

    /// The "]" that closes `[a, "b]", c]`: the first one outside quotes; nil when the list is never closed.
    static func flowClose(_ v: String) -> String.Index? {
        var mark: Character?, escaped = false, itemStart = true
        var i = v.startIndex
        while i < v.endIndex {
            let ch = v[i]
            defer { i = v.index(after: i) }
            if i == v.startIndex, ch == "[" { continue }
            if escaped { escaped = false; continue }
            if let m = mark {
                if m == "\"", ch == "\\" { escaped = true } else if ch == m { mark = nil }
                continue
            }
            if itemStart, ch == "\"" || ch == "'" { mark = ch; itemStart = false; continue }
            if ch == "]" { return i }
            if ch == "," { itemStart = true } else if !ch.isWhitespace { itemStart = false }
        }
        return nil
    }

    /// A line as its text: without the carriage return of a Windows line ending or a leading byte-order mark.
    static func bare(_ line: String) -> String {
        var l = Substring(line)
        if l.unicodeScalars.first == "\u{FEFF}" { l = l.dropFirst() }
        if l.unicodeScalars.last == "\r" { l = Substring(String(l.unicodeScalars.dropLast())) }
        return String(l)
    }

    /// `aliases: [Jordon, "Ellis, J"]` or `aliases: Jordon, J. Ellis` -> the spellings.
    public static func aliases(inFrontmatter value: String) -> [String] {
        var v = value.trimmingCharacters(in: .whitespaces)
        // "[Jordon]  # as he signs": a comment after the list is not a spelling.
        // (The closing bracket is the first one outside quotes: the comment may hold brackets of its own.)
        if v.hasPrefix("["), let close = flowClose(v), v[v.index(after: close)...].trimmingCharacters(in: .whitespaces).hasPrefix("#") {
            v = String(v[...close])
        } else if !v.hasPrefix("["), !v.hasPrefix("\""), !v.hasPrefix("'"), let hash = v.range(of: #"\s#"#, options: .regularExpression) {
            v = String(v[..<hash.lowerBound])   // "aliases: Pet # short"
        }
        if v.hasPrefix("["), v.hasSuffix("]") { v = String(v.dropFirst().dropLast()) }
        var out: [String] = [], current = "", quoted = false
        var mark: Character?, escaped = false
        for ch in v {
            // Inside double quotes a backslash keeps the next character ("Anna \"Annie\" Berg").
            if escaped { current.append(ch); escaped = false; continue }
            if quoted, mark == "\"", ch == "\\" { escaped = true; continue }
            // A quote opens only at the start of an item ("O'Brien" keeps its apostrophe).
            if quoted, ch == mark { quoted = false; mark = nil; continue }
            if !quoted, ch == "\"" || ch == "'", current.trimmingCharacters(in: .whitespaces).isEmpty { quoted = true; mark = ch; continue }
            if ch == ",", !quoted { out.append(current); current = ""; continue }
            current.append(ch)
        }
        out.append(current)
        return out.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// A LinkedIn people search for this person, opened by the owner in their own browser.
    public static func linkedInSearch(name: String, organisation: String?) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let words = [name, organisation ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
        return "https://www.linkedin.com/search/results/people/?keywords="
            + (words.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
    }

    /// The block Distavo owns: when and where this person appeared.
    public static func meetingsBlock(_ p: Person, linkedin: String, organisation: String?, timeZone: TimeZone) -> String {
        func day(_ d: Date) -> String { NoteFrontmatter.dateString(d, timeZone: timeZone) }
        var out = blockStart + "\n## Meetings\n"
        if let last = p.meetings.first, let first = p.meetings.last {
            let n = p.meetings.count
            out += "First seen \(day(first.date)) · last seen \(day(last.date)) · \(n) meeting\(n == 1 ? "" : "s")\n\n"
        }
        for m in p.meetings {
            out += "- \(day(m.date)) · [\(DayLog.linkTitle(m.title))](\(DayLog.relativeLink(m.notePath))) · \(m.byVoice ? "recognised by voice" : (m.spoke ? "spoke" : "listed"))\(m.said.map { " · said: " + oneLine($0) } ?? "")\n"
        }
        if linkedin.isEmpty {
            out += "\n[Find on LinkedIn](\(linkedInSearch(name: p.name, organisation: organisation))), then paste the profile address into `linkedin:` above.\n"
        }
        return out + blockEnd + "\n"
    }

    /// A new page for someone seen for the first time.
    public static func newPage(_ p: Person, timeZone: TimeZone) -> String {
        var out = "---\ntype: person\nname: \(quote(p.name))\n"
        out += "aliases: [\(p.aliases.map(quote).joined(separator: ", "))]\n"
        out += "role: \(quote(p.role ?? ""))\norganisation: \(quote(p.organisation ?? ""))\nlinkedin: \n---\n"
        out += "# \(p.name)\n\n"
        return out + meetingsBlock(p, linkedin: "", organisation: p.organisation, timeZone: timeZone)
    }

    /// An existing page with only Distavo's parts refreshed: the meetings block, and `role:` / `organisation:`
    /// when the owner left them empty. Every other byte stays.
    public static func refreshed(page: String, with p: Person, timeZone: TimeZone) -> String {
        var lines = page.components(separatedBy: "\n")
        var fields = frontmatter(of: page)
        // A page saved with Windows line endings keeps them in what Distavo writes.
        let cr = page.contains("\r\n") ? "\r" : ""
        if bare(lines[0]) == "---", let end = lines.dropFirst().firstIndex(where: { bare($0) == "---" }) {
            for (key, value) in [("role", p.role), ("organisation", p.organisation)] {
                guard let value, !value.isEmpty, (fields[key] ?? "").isEmpty else { continue }
                if let i = lines[1..<end].firstIndex(where: { $0.hasPrefix("\(key):") }) {
                    lines[i] = "\(key): \(quote(value))" + cr
                    fields[key] = value
                }
            }
        }
        let block = meetingsBlock(p, linkedin: fields["linkedin"] ?? "",
                                  organisation: (fields["organisation"] ?? "").isEmpty ? p.organisation : fields["organisation"],
                                  timeZone: timeZone).components(separatedBy: "\n").dropLast().map { $0 + cr }
        // Distavo replaces ONE thing: a complete block, i.e. a start marker followed by an end marker with no
        // other start marker in between (the last such pair). A marker without its partner (the owner deleted
        // one, or pasted a second) is only a stray line: that line is dropped and every line of text around it
        // stays, so a damaged page can never lose what the owner wrote between two markers.
        func isStart(_ l: String) -> Bool { l.hasPrefix("<!-- distavo:meetings:start") }
        func isEnd(_ l: String) -> Bool { l.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r")) == blockEnd }
        var whole: ClosedRange<Int>?
        for s in lines.indices.reversed() where isStart(lines[s]) {
            let after = lines.index(after: s)
            guard let e = lines[after...].firstIndex(where: isEnd) else { continue }
            if !lines[after..<e].contains(where: isStart) { whole = s...e; break }
        }
        var out: [String] = []
        for (i, line) in lines.enumerated() {
            if let whole, whole.contains(i) {
                if i == whole.lowerBound { out += block }
            } else if !isStart(line) && !isEnd(line) {
                out.append(line)
            }
        }
        if whole == nil {
            while out.last == "" { out.removeLast() }
            out += [cr] + block + [""]
        }
        return out.joined(separator: "\n")
    }

    public static func index(_ rows: [(person: Person, file: String, fields: [String: String])], timeZone: TimeZone) -> String {
        var out = "---\ntype: people-index\n---\n# People\n\n"
        guard !rows.isEmpty else {
            return out + "Nobody yet. Name a speaker in the Notes window (Rename Speakers) or answer \"who was in this meeting?\" after a recording, then update again.\n"
        }
        out += "| Person | Role | Organisation | Meetings | Last seen |\n|---|---|---|---|---|\n"
        // A page whose notes are gone sorts by the day its own block says, among the others.
        func day(_ r: (person: Person, file: String, fields: [String: String])) -> String {
            r.person.meetings.first.map { NoteFrontmatter.dateString($0.date, timeZone: timeZone) } ?? (r.fields["_last_seen"] ?? "")
        }
        let sorted = rows.sorted {
            if day($0) != day($1) { return day($0) > day($1) }
            let a = $0.person.meetings.first?.date ?? .distantPast, b = $1.person.meetings.first?.date ?? .distantPast
            return a != b ? a > b : $0.person.name.lowercased() < $1.person.name.lowercased()
        }
        func cell(_ s: String) -> String { s.replacingOccurrences(of: "|", with: "/").replacingOccurrences(of: "\n", with: " ") }
        for r in sorted {
            let last = r.person.meetings.first.map { NoteFrontmatter.dateString($0.date, timeZone: timeZone) } ?? (r.fields["_last_seen"] ?? "")
            let link = r.file.addingPercentEncoding(withAllowedCharacters: DayLog.linkSafe) ?? r.file
            let count = r.person.meetings.isEmpty ? "" : String(r.person.meetings.count)
            out += "| [\(DayLog.linkTitle(cell(r.person.name)))](\(link)) | \(cell(r.fields["role"] ?? "")) | \(cell(r.fields["organisation"] ?? "")) | \(count) | \(last) |\n"
        }
        return out
    }

    /// The people grouped by the `organisation:` of their page: the organisation seen most recently first, the
    /// people of each most recently seen first. Spellings that differ only in capitals or spacing are one
    /// organisation (the spelling used by most pages names it). People without an organisation come last.
    public static func organisations(_ rows: [(person: Person, file: String, fields: [String: String])], timeZone: TimeZone) -> String {
        var out = "---\ntype: people-organisations\n---\n# Organisations\n"
        guard !rows.isEmpty else { return out + "\nNobody yet.\n" }
        func last(_ p: Person) -> Date { p.meetings.first?.date ?? .distantPast }
        var groups: [String: [(person: Person, file: String, fields: [String: String])]] = [:]
        for r in rows {
            let org = oneLine(r.fields["organisation"] ?? "").split(separator: " ").joined(separator: " ")
            groups[org.lowercased(), default: []].append(r)
        }
        let keys = groups.keys.sorted { a, b in
            if a.isEmpty != b.isEmpty { return b.isEmpty }
            let la = groups[a]!.map { last($0.person) }.max()!, lb = groups[b]!.map { last($0.person) }.max()!
            return la != lb ? la > lb : a < b
        }
        for key in keys {
            let members = groups[key]!.sorted { last($0.person) != last($1.person) ? last($0.person) > last($1.person) : $0.person.name.lowercased() < $1.person.name.lowercased() }
            var spelled: [String: Int] = [:]
            for m in members { spelled[oneLine(m.fields["organisation"] ?? "").split(separator: " ").joined(separator: " "), default: 0] += 1 }
            let title = key.isEmpty ? "No organisation yet" : spelled.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }[0].key
            let meetings = Set(members.flatMap { $0.person.meetings.map(\.base) }).count
            out += "\n## \(DayLog.linkTitle(title))\n\(members.count) \(members.count == 1 ? "person" : "people") · \(meetings) meeting\(meetings == 1 ? "" : "s")\n\n"
            for m in members {
                let link = m.file.addingPercentEncoding(withAllowedCharacters: DayLog.linkSafe) ?? m.file
                let role = oneLine(m.fields["role"] ?? "")
                let seen = m.person.meetings.first.map { NoteFrontmatter.dateString($0.date, timeZone: timeZone) } ?? (m.fields["_last_seen"] ?? "")
                out += "- [\(DayLog.linkTitle(m.person.name))](\(link))\(role.isEmpty ? "" : " · \(role)")\(seen.isEmpty ? "" : " · last seen \(seen)")\n"
            }
        }
        return out
    }

    // MARK: Update

    /// Creates the missing pages, refreshes the others and rewrites the index. A page whose person no longer has
    /// a confirmed meeting is left as it is (the owner's notes are never deleted).
    @discardableResult
    public static func update(notesDir: URL, workDir: URL, ownerName: String = "",
                              glossary: NameGlossary = NameGlossary(), timeZone: TimeZone = .current) throws -> Summary {
        let fm = FileManager.default
        let dir = folder(notesDir: notesDir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        // Existing pages: their names and aliases decide where a spelling belongs.
        var known: [String: String] = [:], pageOf: [String: URL] = [:]
        let files = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "md" && !$0.lastPathComponent.hasPrefix("_")
                && !NoteVersions.isBackupName($0.lastPathComponent) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let fields = frontmatter(of: text)
            guard fields["type"] == "person" else { continue }
            let name = (fields["name"] ?? "").isEmpty ? file.deletingPathExtension().lastPathComponent : fields["name"]!
            // Two files with the same `name:` (a Finder "… copy.md"): the one called after the person is the page.
            let stem = file.deletingPathExtension().lastPathComponent.lowercased()
            if let other = pageOf[name.lowercased()],
               stem != name.lowercased() || other.deletingPathExtension().lastPathComponent.lowercased() == name.lowercased() { continue }
            pageOf[name.lowercased()] = file
            for s in [name] + aliases(inFrontmatter: fields["aliases"] ?? "") where known[s.lowercased()] == nil {
                known[s.lowercased()] = name
            }
        }

        var summary = Summary(index: dir.appendingPathComponent(indexName))
        var rows: [(person: Person, file: String, fields: [String: String])] = []
        for p in collect(notesDir: notesDir, workDir: workDir, ownerName: ownerName, glossary: glossary,
                         known: known, timeZone: timeZone) {
            var target = pageOf[p.name.lowercased()] ?? dir.appendingPathComponent(fileName(for: p.name))
            // "Anna Strauß" and "Anna Strauss" are one file to the disk and two people here: the second gets a
            // file of their own instead of rewriting the first one's page.
            var n = 2
            while pageOf[p.name.lowercased()] == nil, let there = try? String(contentsOf: target, encoding: .utf8),
                  let theirs = knownPage(there, file: target), theirs.name.lowercased() != p.name.lowercased(), n < 50 {
                target = dir.appendingPathComponent(fileName(for: "\(p.name) \(n)")); n += 1
            }
            let text: String
            if let old = try? String(contentsOf: target, encoding: .utf8) {
                text = refreshed(page: old, with: p, timeZone: timeZone)
                if text == old { summary.unchanged += 1 } else { summary.updated.append(p.name) }
                if text != old {
                    try text.write(to: target, atomically: true, encoding: .utf8)
                    PeopleMerge.noteFilled(page: p.name, old: old, new: text, notesDir: notesDir)
                }
            } else if !fm.fileExists(atPath: target.path) {
                text = newPage(p, timeZone: timeZone)
                try text.write(to: target, atomically: true, encoding: .utf8)
                summary.created.append(p.name)
            } else {
                // The file is there but is not UTF-8 text (saved as UTF-16 or Latin-1): it is the owner's, so it
                // is neither replaced nor listed.
                summary.unreadable.append(target.lastPathComponent)
                continue
            }
            rows.append((p, target.lastPathComponent, frontmatter(of: text)))
        }
        // A page whose person has no confirmed meeting left (the note was deleted, or the name un-renamed) stays
        // in the lists: the page is still there and still the owner's. Its own block says when they were last seen.
        let listed = Set(rows.map(\.file))
        for (_, file) in pageOf.sorted(by: { $0.key < $1.key }) where !listed.contains(file.lastPathComponent) {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            var fields = frontmatter(of: text)
            let name = (fields["name"] ?? "").isEmpty ? file.deletingPathExtension().lastPathComponent : fields["name"]!
            fields["_last_seen"] = lastSeen(inBlockOf: text)
            rows.append((Person(name: name), file.lastPathComponent, fields))
        }
        let indexText = index(rows, timeZone: timeZone)
        if (try? String(contentsOf: summary.index, encoding: .utf8)) != indexText {
            try indexText.write(to: summary.index, atomically: true, encoding: .utf8)
        }
        let orgURL = dir.appendingPathComponent(organisationsName), orgText = organisations(rows, timeZone: timeZone)
        if (try? String(contentsOf: orgURL, encoding: .utf8)) != orgText {
            try orgText.write(to: orgURL, atomically: true, encoding: .utf8)
        }
        return summary
    }

    // MARK: Known people in the summary prompt (`summarise.known_people`)

    /// What a page says about one person, as the owner wrote it.
    public struct Known: Equatable, Sendable {
        public var name: String
        public var aliases: [String]
        public var role: String
        public var organisation: String
        /// "last seen" of the page's Meetings block (yyyy-MM-dd), "" when the page has none.
        public var lastSeen: String = ""

        /// How this person is written into the participants answer: "Petra Novak (Acme Cooling) - buyer".
        /// Commas and semicolons separate people there, so they are taken out of the page's own text.
        public var participantsEntry: String {
            func flat(_ s: String) -> String {
                PeoplePages.oneLine(s).replacingOccurrences(of: ",", with: " ").replacingOccurrences(of: "(", with: " ")
                    .replacingOccurrences(of: ")", with: " ").split(separator: " ").joined(separator: " ")
            }
            let org = flat(organisation), job = flat(role)
            return flat(name) + (org.isEmpty ? "" : " (\(org))") + (job.isEmpty ? "" : " - \(job)")
        }
    }

    /// The people to offer in the "who was in this meeting?" question: most recently seen first, then by name.
    public static func suggestions(notesDir: URL, limit: Int = 20) -> [Known] {
        Array(known(notesDir: notesDir).filter { isPersonName($0.name) }
            .sorted { $0.lastSeen != $1.lastSeen ? $0.lastSeen > $1.lastSeen : $0.name.lowercased() < $1.name.lowercased() }
            .prefix(limit))
    }

    /// `current` with `person` added at the end; unchanged when that person is already named in it.
    public static func adding(_ person: Known, to current: String) -> String {
        let text = current.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;")))
        let named = parseParticipants(text).map { $0.name.lowercased() }
        if named.contains(where: { n in ([person.name] + person.aliases).contains { $0.lowercased() == n } }) { return current }
        return text.isEmpty ? person.participantsEntry : text + ", " + person.participantsEntry
    }

    public static let maxKnownInPrompt = 12
    static let knownLead = "From the note owner's own notes about these people (their role and employer, not something said in this meeting): "

    /// Every person page of the notes folder, by file name order.
    public static func known(notesDir: URL) -> [Known] { knownFiles(notesDir: notesDir).map(\.known) }

    /// The page file of a person, by name; nil when they have none.
    public static func pageURL(for name: String, notesDir: URL) -> URL? {
        // Compared as the pages are told apart everywhere else ("Strauß" and "Strauss" are two people).
        knownFiles(notesDir: notesDir).first { $0.known.name.lowercased() == name.lowercased() }?.url
    }

    /// The same pages with the file each one is and its text (`PeopleMerge` rewrites them).
    static func knownFiles(notesDir: URL) -> [(known: Known, url: URL, text: String)] {
        let dir = folder(notesDir: notesDir)
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "md" && !$0.lastPathComponent.hasPrefix("_")
                && !NoteVersions.isBackupName($0.lastPathComponent) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var out: [(known: Known, url: URL, text: String)] = []
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8), let k = knownPage(text, file: file) else { continue }
            // Two files with the same `name:` (a Finder "… copy.md"): the one called after the person is the
            // page, as in `update`.
            if let i = out.firstIndex(where: { $0.known.name.lowercased() == k.name.lowercased() }) {
                let stem = file.deletingPathExtension().lastPathComponent.lowercased()
                let held = out[i].url.deletingPathExtension().lastPathComponent.lowercased()
                if stem == k.name.lowercased(), held != k.name.lowercased() { out[i] = (k, file, text) }
                continue
            }
            out.append((k, file, text))
        }
        return out
    }

    /// What one page's text says; nil when it is not a person page.
    static func knownPage(_ text: String, file: URL) -> Known? {
        let f = frontmatter(of: text)
        guard f["type"] == "person" else { return nil }
        let name = (f["name"] ?? "").isEmpty ? file.deletingPathExtension().lastPathComponent : f["name"]!
        return Known(name: name, aliases: aliases(inFrontmatter: f["aliases"] ?? ""),
                     role: f["role"] ?? "", organisation: f["organisation"] ?? "", lastSeen: lastSeen(inBlockOf: text))
    }

    /// "last seen" (yyyy-MM-dd) of the Meetings block Distavo wrote into a page; "" when there is none.
    static func lastSeen(inBlockOf text: String) -> String {
        var block = text.range(of: "<!-- distavo:meetings:start").map { text[$0.upperBound...] } ?? Substring("")
        if let end = block.range(of: blockEnd) { block = block[..<end.lowerBound] }   // the owner's text after it is theirs
        guard let r = block.range(of: #"last seen \d{4}-\d{2}-\d{2}"#, options: .regularExpression) else { return "" }
        return String(block[r].dropFirst("last seen ".count))
    }

    /// The page for a name as typed or recognised: exact name or alias, else a first name that only one page has.
    static func page(for spelled: String, in known: [Known]) -> Known? {
        let want = spelled.lowercased()
        if let exact = known.first(where: { ([$0.name] + $0.aliases).contains { $0.lowercased() == want } }) { return exact }
        guard !want.contains(" ") else { return nil }
        let byFirst = known.filter { $0.name.lowercased().split(separator: " ").first.map(String.init) == want }
        return byFirst.count == 1 ? byFirst[0] : nil
    }

    /// The participants line for the summary prompt with what the owner's people pages say about the people in
    /// this meeting (the names in the participants answer plus `alsoPresent`, e.g. speakers named by voice or by
    /// a rename). Only a page with a role or an organisation adds anything; with nothing to add the input comes
    /// back untouched (nil stays nil), so the prompt is byte-identical.
    public static func participants(_ line: String?, alsoPresent: [String], notesDir: URL) -> String? {
        let pages = known(notesDir: notesDir)
        guard !pages.isEmpty else { return line }
        var seen = Set<String>(), facts: [String] = []
        for name in parseParticipants(line ?? "").map(\.name) + alsoPresent.sorted() {
            guard let p = page(for: name, in: pages), seen.insert(p.name.lowercased()).inserted else { continue }
            // What the owner already typed for this meeting (e.g. picked from the people list) is not repeated.
            let typed = (line ?? "").lowercased()
            let about = [p.role, p.organisation].map(oneLine).filter { fact in
                !fact.isEmpty && typed.range(of: #"(?<![\p{L}\d])"# + NSRegularExpression.escapedPattern(for: fact.lowercased()) + #"(?![\p{L}\d])"#,
                                             options: .regularExpression) == nil }
                .joined(separator: ", ")
            guard !about.isEmpty else { continue }
            facts.append("\(oneLine(p.name)): \(about)")
            if facts.count == maxKnownInPrompt { break }
        }
        guard !facts.isEmpty else { return line }
        let own = line?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (own.isEmpty ? "" : own + ". ") + knownLead + facts.joined(separator: "; ") + "."
    }

    /// One line, no characters that could close the prompt's sentence structure, at most 80 characters.
    static func oneLine(_ s: String) -> String {
        let flat = s.components(separatedBy: .newlines).joined(separator: " ")
            .replacingOccurrences(of: ";", with: ",").trimmingCharacters(in: .whitespaces)
        return String(flat.prefix(80))
    }

    // MARK: Internals

    static func fileName(for name: String) -> String {
        let cleaned = name.map { ch -> Character in (ch == ":" || ch == "/" || ch == "\\") ? "-" : ch }
        // A leading dot would hide the file; a trailing one is part of the name ("Anna Smith Jr.").
        var stem = String(cleaned).trimmingCharacters(in: .whitespaces)
        while stem.hasPrefix(".") { stem = String(stem.dropFirst()).trimmingCharacters(in: .whitespaces) }
        return (stem.isEmpty || stem.hasPrefix("_") ? "Person \(stem)" : stem) + ".md"
    }

    /// YAML-safe scalar: quoted only when it has to be.
    static func quote(_ s: String) -> String {
        let risky = s.contains(": ") || s.contains("#") || s.contains(",") || s.contains("\"") || s.contains("[")
            || s.contains("]") || s.hasPrefix("'") || s.hasPrefix("-") || s != s.trimmingCharacters(in: .whitespaces)
            || (s.first.map { "@&*!%{}|>?`".contains($0) } ?? false)
        guard risky else { return s }
        return "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func unquote(_ s: String) -> String {
        if s.count >= 2, s.hasPrefix("'"), s.hasSuffix("'") { return String(s.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'") }
        guard s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") else { return s }
        return String(s.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
    }
}
