// MeetingBrief.swift — a brief before a meeting (people directory idea 5, 2026-11-23). No model.
//
// For each person named: what the owner's people page says (role, organisation), the last meetings with them
// and the tasks still open from those meetings, split into theirs and everybody else's. Everything comes
// from files the owner already has: owner-confirmed names (`PeoplePages.collect`), the people pages and the
// `- [ ]` lines of the notes (`ActionItems`). A name nobody confirmed gets one line saying so; nothing is guessed.
//
// The brief is written to `notes/people/_Brief.md` (replaced each time; it is Distavo's file, like `_People.md`)
// with task lines as plain text, never as `- [ ]`, so Action Items never lists a task twice. Same files in,
// same bytes out apart from the date in the heading. Pure apart from `write`.

import Foundation

public enum MeetingBrief {
    public static let fileName = "_Brief.md"
    public static let meetingsShown = 3
    public static let tasksShown = 8

    public struct Entry: Equatable, Sendable {
        public var asked: String
        public var person: PeoplePages.Person?
        public var role: String = ""
        public var organisation: String = ""
        /// Open tasks from their meetings whose owner is this person.
        public var theirs: [ActionItem] = []
        /// The other open tasks of the same meetings.
        public var others: [ActionItem] = []
    }

    /// The names of a typed list ("Anna (Acme) - buyer, Pere and Jo") without what was typed about them.
    public static func names(in text: String) -> [String] {
        var out: [String] = [], seen = Set<String>()
        for item in PeoplePages.listItems(text) {
            // "Pere and Jo" are two people; "Anna (Marks and Spencer)" and "Anna - sales and marketing" are one:
            // an item is cut at and/& only outside brackets and only when every part then reads as a name.
            var parts: [String] = [], depth = 0, current = ""
            for word in item.split(separator: " ").map(String.init) {
                depth += word.filter { $0 == "(" }.count
                if depth == 0, ["and", "&", "i", "y"].contains(word.lowercased()) { parts.append(current); current = "" }
                else { current += (current.isEmpty ? "" : " ") + word }
                depth = max(0, depth - word.filter { $0 == ")" }.count)
            }
            parts.append(current)
            func name(_ s: String) -> String? {
                if let n = PeoplePages.parseParticipants(s).first?.name { return n }
                // A name typed in lower case ("pere") is still a name; a description or the owner's own entry is not.
                let t = s.trimmingCharacters(in: .whitespaces)
                guard let first = t.first, first.isLowercase else { return nil }
                return PeoplePages.parseParticipants(first.uppercased() + t.dropFirst()).first.map { _ in
                    t.split(whereSeparator: { " (-:".contains($0) }).first.map(String.init) ?? t
                }
            }
            let each = parts.map(name)
            // Something was typed about a person (a role, a company): then only capitalised parts are people.
            let described = item.contains(" - ") || item.contains(":") || item.contains("(")
            let split = parts.count > 1 && each.allSatisfy { $0 != nil }
                && (!described || parts.allSatisfy { SpeakerHints.startsWithAName($0.trimmingCharacters(in: .whitespaces)) })
            for n in (split ? each : [name(item)]).compactMap({ $0 })
            where seen.insert(n.lowercased()).inserted { out.append(n) }
        }
        return out
    }

    /// Two spellings of one full name as a transcript may hear it: the same number of words (two or more), each
    /// word the same or, when it has four letters or more, one letter changed, added or missing.
    static func nearSpelling(_ a: String, _ b: String) -> Bool {
        let x = a.lowercased().split(separator: " ").map(Array.init), y = b.lowercased().split(separator: " ").map(Array.init)
        guard x.count == y.count, x.count >= 2, x != y else { return false }
        func oneOff(_ p: [Character], _ q: [Character]) -> Bool {
            let (s, l) = p.count <= q.count ? (p, q) : (q, p)
            guard s.count >= 4, l.count - s.count <= 1 else { return false }
            var i = 0
            while i < s.count, s[i] == l[i] { i += 1 }
            return s.count == l.count ? Array(s[(i + 1)...]) == Array(l[(i + 1)...]) : Array(s[i...]) == Array(l[(i + 1)...])
        }
        return zip(x, y).allSatisfy { $0 == $1 || oneOff($0, $1) }
    }

    /// One entry per asked name, in the order asked; two spellings of one person give one entry.
    public static func entries(for names: [String], notesDir: URL, workDir: URL, ownerName: String = "",
                               glossary: NameGlossary = NameGlossary(), timeZone: TimeZone = .current) -> [Entry] {
        let pages = PeoplePages.known(notesDir: notesDir)
        var spellings: [String: String] = [:]
        for p in pages { for s in [p.name] + p.aliases where spellings[s.lowercased()] == nil { spellings[s.lowercased()] = p.name } }
        let people = PeoplePages.collect(notesDir: notesDir, workDir: workDir, ownerName: ownerName, glossary: glossary,
                                         known: spellings, timeZone: timeZone)
        let open = ActionItems.scan(notesDir: notesDir).flatMap(\.items)
        var out: [Entry] = [], seen = Set<String>()
        for asked in names {
            var page = PeoplePages.page(for: asked, in: pages)
            var want = (page?.name ?? asked).lowercased()
            func firstName(_ s: String) -> String { s.lowercased().split(separator: " ").first.map(String.init) ?? "" }
            let exact = pages.contains { ([$0.name] + $0.aliases).contains { $0.lowercased() == asked.lowercased() } }
                || people.contains { ([$0.name] + $0.aliases).contains { $0.lowercased() == asked.lowercased() } }
            if !exact, !asked.contains(" ") {
                // A bare first name names someone only when ONE person has it, counting pages and confirmed
                // people together; with two Annas nothing is guessed.
                let sharing = Set(pages.map(\.name).filter { firstName($0) == asked.lowercased() }.map { $0.lowercased() })
                    .union(people.map(\.name).filter { firstName($0) == asked.lowercased() }.map { $0.lowercased() })
                if sharing.count == 1 { want = sharing.first! } else { page = nil; want = asked.lowercased() }
            }
            let person = people.first { $0.name.lowercased() == want || $0.aliases.contains { $0.lowercased() == want } }
            guard seen.insert((person?.name ?? page?.name ?? asked).lowercased()).inserted else { continue }
            var e = Entry(asked: asked, person: person, role: page?.role ?? person?.role ?? "",
                          organisation: page?.organisation ?? person?.organisation ?? "")
            if e.role.isEmpty { e.role = person?.role ?? "" }
            if e.organisation.isEmpty { e.organisation = person?.organisation ?? "" }
            if let person {
                let paths = Set(person.meetings.map { $0.notePath.standardizedFileURL.path })
                let called = Set(([person.name] + person.aliases + (page?.aliases ?? [])).map { $0.lowercased() })
                let first = person.name.lowercased().split(separator: " ").first.map(String.init) ?? ""
                for item in open where paths.contains(URL(fileURLWithPath: item.notePath).standardizedFileURL.path) {
                    let owner = (item.owner ?? "").lowercased().trimmingCharacters(in: .whitespaces)
                    // "owner: Anna" is this person's only when no other confirmed person is an Anna too.
                    let firstIsTheirs = owner == first && people.filter { firstName($0.name) == first }.count == 1
                    // The transcript's spelling of the name ("Oscar Lind" for Oskar Lind): theirs when it is one
                    // letter off per word and nobody confirmed is called exactly that.
                    let heard = !owner.isEmpty && called.contains { nearSpelling(owner, $0) }
                        && !people.contains { other in ([other.name] + other.aliases).contains { $0.lowercased() == owner } }
                    if !owner.isEmpty, called.contains(owner) || firstIsTheirs || heard { e.theirs.append(item) } else { e.others.append(item) }
                }
            }
            out.append(e)
        }
        return out
    }

    public static func markdown(_ entries: [Entry], now: Date = Date(), timeZone: TimeZone = .current) -> String {
        func day(_ d: Date) -> String { NoteFrontmatter.dateString(d, timeZone: timeZone) }
        func line(_ s: String) -> String { PeoplePages.oneLine(s).replacingOccurrences(of: "[ ]", with: "").trimmingCharacters(in: .whitespaces) }
        var out = "---\ntype: people-brief\n---\n# Brief · \(day(now))\n"
        if entries.isEmpty { return out + "\nNobody named. Type who is coming, separated by commas.\n" }
        for e in entries {
            let name = e.person?.name ?? e.asked
            out += "\n## \(DayLog.linkTitle(name))\n"
            let about = [e.role, e.organisation].map(line).filter { !$0.isEmpty }.joined(separator: ", ")
            if !about.isEmpty { out += about + "\n" }
            guard let p = e.person else {
                out += "No meeting with a confirmed speaker or participant of this name yet.\n"
                continue
            }
            let n = p.meetings.count
            out += "\(n) meeting\(n == 1 ? "" : "s") · last \(p.meetings.first.map { day($0.date) } ?? "")\n\n"
            for m in p.meetings.prefix(meetingsShown) {
                out += "- \(day(m.date)) · [\(DayLog.linkTitle(m.title))](\(DayLog.relativeLink(m.notePath)))\(m.said.map { " · said: " + line($0) } ?? "")\n"
            }
            for (title, items) in [("They still owe", e.theirs), ("Also open from those meetings", e.others)] where !items.isEmpty {
                out += "\n\(title):\n"
                for i in items.prefix(tasksShown) {
                    let tail = [i.owner.map { "owner: \(line($0))" }, i.due.map { "due: \($0)" }].compactMap { $0 }.joined(separator: "; ")
                    out += "- \(line(i.title))\(tail.isEmpty ? "" : " (\(tail))")\n"
                }
                if items.count > tasksShown { out += "- and \(items.count - tasksShown) more\n" }
            }
        }
        return out
    }

    /// Writes the brief into the people folder and returns its location.
    @discardableResult
    public static func write(for names: [String], notesDir: URL, workDir: URL, ownerName: String = "",
                             glossary: NameGlossary = NameGlossary(), now: Date = Date(),
                             timeZone: TimeZone = .current) throws -> URL {
        let dir = PeoplePages.folder(notesDir: notesDir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(fileName)
        try markdown(entries(for: names, notesDir: notesDir, workDir: workDir, ownerName: ownerName, glossary: glossary,
                             timeZone: timeZone), now: now, timeZone: timeZone)
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
