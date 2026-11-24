// AskPeople.swift — "what did I promise Petra?" (people directory idea 8, 2026-11-23). No model here.
//
// When a question asked across all notes names a person the owner confirmed (a renamed speaker or a listed
// participant, `PeoplePages.collect`), the excerpts from that person's meetings go first. Nothing else about
// Ask changes: the same index, the same budget, the same local-only rules; a question that names nobody
// retrieves exactly as before. A name is matched as whole words: the full name, an alias, or a first name
// that only one confirmed person has. The longest match wins (2026-11-24, found on real data): the words of
// "Anna Puig" in a question cannot also name a page "Anna", nor "Pere" inside "Pere Soler" the person whose
// alias is "Pere"; an "Anna" elsewhere in the same question still names the one-word page.

import Foundation

public enum AskPeople {
    /// More passages are fetched when a person is named, so their meetings are among them.
    public static let widenedLimit = 30

    /// The confirmed people a question names, in the order of `people`.
    public static func named(in question: String, people: [PeoplePages.Person]) -> [PeoplePages.Person] {
        let ns = question as NSString
        // The question's words, lower case, each with where it starts in `question` (UTF-16).
        var words: [(word: String, at: Int)] = []
        var start: Int?
        let units = Array(question.utf16) + [0x20]
        for (i, unit) in units.enumerated() {
            let isWordUnit = UTF16.isLeadSurrogate(unit) || UTF16.isTrailSurrogate(unit)
                || Unicode.Scalar(unit).map(CharacterSet.alphanumerics.contains) == true
            if isWordUnit, start == nil { start = i }
            if !isWordUnit, let s = start {
                let piece = ns.substring(with: NSRange(location: s, length: i - s)).lowercased()
                for w in piece.components(separatedBy: CharacterSet.alphanumerics.inverted) where !w.isEmpty { words.append((w, s)) }
                start = nil
            }
        }
        // Where the words of `spelled` stand in the question, as word ranges.
        func occurrences(_ spelled: String) -> [Range<Int>] {
            let parts = spelled.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
            guard !parts.isEmpty, parts.count <= words.count else { return [] }
            return (0...(words.count - parts.count)).filter { i in parts.indices.allSatisfy { words[i + $0].word == parts[$0] } }
                .map { $0..<($0 + parts.count) }
        }
        // "Will", "May", "Mark", "Jo": a one-word name that is also an everyday word names the person only
        // when it is written with its capital in the middle of a sentence ("what did Will say", not
        // "Will this work?" or "jo crec que").
        func mentions(_ spelled: String) -> [Range<Int>] {
            let trimmed = spelled.trimmingCharacters(in: .whitespaces)
            guard !trimmed.contains(" "), everydayWords.contains(trimmed.lowercased()) else { return occurrences(spelled) }
            // A question typed all in capitals says nothing by its capitals.
            if question == question.uppercased() { return occurrences(spelled) }
            // The word that starts at a regex match (a match always starts a word).
            func word(at location: Int) -> [Range<Int>] {
                (words.lastIndex { $0.at <= location }).map { [$0..<($0 + 1)] } ?? []
            }
            let capital = NSRegularExpression.escapedPattern(for: trimmed.prefix(1).uppercased() + trimmed.dropFirst().lowercased())
            // Mid-sentence: after a word, a comma or a semicolon on the same line (anything else may have ended a
            // sentence: a closing quote, a colon, a dash, an emoji), an opening quote or bracket allowed in
            // between; or right after the Catalan article ("l'Alba", "d'Àngel").
            let inside = #"(?<=[\p{L}\d,;][ \t]{1,3}|[\p{L}\d,;][ \t]{1,3}["'“‘«(]|(?<![\p{L}])[lLdD]['’])"# + capital + #"(?![\p{L}\d])"#
            // "Will's plan" at the very start is the person too.
            let possessive = "^\\s*" + capital + #"['’]s(?![\p{L}\d])"#
            // (The name is then the question's first word.)
            let atStart = question.range(of: possessive, options: .regularExpression) != nil && !words.isEmpty ? [0..<1] : []
            guard let regex = try? NSRegularExpression(pattern: inside) else { return atStart }
            let isMonth = englishMonths.contains(trimmed.lowercased())
            // "…in the May board meeting", "by June": an English month after such a word is the month. Each
            // mention is judged on its own ("What did May say in May?" names May). Spanish and Catalan write
            // their months in lower case, so "en Julio" is Julio.
            return atStart + regex.matches(in: question, range: NSRange(location: 0, length: ns.length)).filter { m in
                guard isMonth else { return true }
                return ns.substring(to: m.range.location)
                    .range(of: #"(?i)(?<![\p{L}])(in|of|by|until|till|since|during|before|after|next|last|this|early|late|mid|the)\s+$"#,
                           options: .regularExpression) == nil
            }.flatMap { word(at: $0.range.location) }
        }
        var firstNames: [String: Int] = [:]
        for p in people { if let f = p.name.lowercased().split(separator: " ").first { firstNames[String(f), default: 0] += 1 } }
        // Every place a person is mentioned: by their name, an alias, or a first name only they have.
        var found: [(person: Int, words: Range<Int>)] = []
        for (i, p) in people.enumerated() {
            for spelled in [p.name] + p.aliases { found += mentions(spelled).map { (i, $0) } }
            if let first = p.name.split(separator: " ").first.map(String.init), first.count >= 3, firstNames[first.lowercased()] == 1 {
                found += mentions(first).map { (i, $0) }
            }
        }
        // The longest match wins: words already taken by a longer mention name nobody else. Mentions of the same
        // length over the same words (two people sharing a spelling) all stand, as before.
        var taken: [Range<Int>] = [], named = Set<Int>()
        for length in Set(found.map(\.words.count)).sorted(by: >) {
            let kept = found.filter { $0.words.count == length && !taken.contains(where: $0.words.overlaps) }
            named.formUnion(kept.map(\.person))
            taken += kept.map(\.words)
        }
        return people.indices.filter(named.contains).map { people[$0] }
    }

    static let englishMonths: Set<String> = ["may", "april", "june", "august"]

    /// Names that are also everyday words in English, Catalan or Spanish.
    static let everydayWords: Set<String> = [
        "will", "may", "mark", "bill", "rose", "grace", "hope", "joy", "faith", "max", "art", "pat", "sue", "rob", "don",
        "ray", "jo", "dawn", "april", "june", "august", "summer", "autumn", "frank", "grant", "chase", "hunter", "mason",
        "page", "penny", "rich", "miles", "drew", "nick", "jack", "lance", "pierce", "wade", "dean", "earl", "chip", "dot",
        "pau", "mar", "sol", "cel", "blanca", "rosa", "pilar", "dolors", "neus", "clara", "alba", "leo", "angel", "cruz",
        "paz", "luz", "esperanza", "victoria", "gloria", "amparo", "consuelo", "remei", "linda", "bella", "ivy", "lily",
        "guy", "ben", "marina", "aurora", "nieves", "dolores", "àngel", "ángel", "abril", "julio", "juliol", "mayo",
        "bo", "dolça", "rocío", "rocio", "lluna", "iris", "olive", "mia", "jan", "al"]

    /// The recordings (bases) of the people a question names; empty when it names nobody.
    public static func bases(for question: String, notesDir: URL, workDir: URL, ownerName: String = "",
                             timeZone: TimeZone = .current) -> Set<String> {
        var spellings: [String: String] = [:]
        for p in PeoplePages.known(notesDir: notesDir) {
            for s in [p.name] + p.aliases where spellings[s.lowercased()] == nil { spellings[s.lowercased()] = p.name }
        }
        let people = PeoplePages.collect(notesDir: notesDir, workDir: workDir, ownerName: ownerName, known: spellings, timeZone: timeZone)
        return Set(named(in: question, people: people).flatMap { $0.meetings.map(\.base) })
    }

    /// `passages` with those of `bases` first (both groups keep the index's order), cut to `limit`.
    public static func preferring(_ passages: [SearchPassage], bases: Set<String>, limit: Int) -> [SearchPassage] {
        guard !bases.isEmpty else { return Array(passages.prefix(limit)) }
        return Array((passages.filter { bases.contains($0.base) } + passages.filter { !bases.contains($0.base) }).prefix(limit))
    }
}
