import XCTest
@testable import DistavoCore

/// Regression tests for the people-pages bug hunt of 2026-11-23. Synthetic names only.
final class HardeningPeoplePagesTests: XCTestCase {
    private let zone = TimeZone(identifier: "Europe/London")!

    /// One note per (base, renamed speakers, participants answer).
    private func env(_ meetings: [(String, [String: String], String?)]) throws -> (notes: URL, work: URL, people: URL) {
        let root = TestTemp.root.appendingPathComponent("distavo-hardpeople-\(UUID().uuidString)")
        let notes = root.appendingPathComponent("notes"), work = root.appendingPathComponent("work")
        let people = PeoplePages.folder(notesDir: notes)
        for d in [work, people] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        for (base, names, line) in meetings {
            try "# Call\n\nText.\n".write(to: notes.appendingPathComponent("\(base).md"), atomically: true, encoding: .utf8)
            if !names.isEmpty { try SpeakerNames(names: names).encoded().write(to: SpeakerNames.url(workDir: work, base: base)) }
            if let line { try SpeakerHints(participants: line).save(workDir: work, base: base) }
        }
        return (notes, work, people)
    }
    private let b1 = "Meeting_2026-11-18_09.00.00", b2 = "Meeting_2026-11-19_14.30.00"
    private func update(_ e: (notes: URL, work: URL, people: URL)) throws -> PeoplePages.Summary {
        try PeoplePages.update(notesDir: e.notes, workDir: e.work, ownerName: "Dana Owner", timeZone: zone)
    }
    private func read(_ e: (notes: URL, work: URL, people: URL), _ file: String) throws -> String {
        try String(contentsOf: e.people.appendingPathComponent(file), encoding: .utf8)
    }
    private func write(_ e: (notes: URL, work: URL, people: URL), _ file: String, _ text: String) throws {
        try text.write(to: e.people.appendingPathComponent(file), atomically: true, encoding: .utf8)
    }

    func testAPageThatIsNotUTF8IsNeverReplaced() throws {
        let e = try env([(b1, ["SPEAKER_01": "Oskar Lind"], nil)])
        let url = e.people.appendingPathComponent("Oskar Lind.md")
        let original = "---\ntype: person\nname: Oskar Lind\n---\nOWNER NOTE\n".data(using: .utf16)!
        try original.write(to: url)
        let s = try update(e)
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(s.unreadable, ["Oskar Lind.md"])
        XCTAssertEqual(s.created, [])
    }

    func testOrganisationsWithOfAreOneName() {
        func first(_ t: String) -> (String?, String?) { let p = PeoplePages.parseParticipants(t).first; return (p?.role, p?.organisation) }
        XCTAssertTrue(first("Anna Berg (University of Cambridge)") == (nil, "University of Cambridge"))
        XCTAssertTrue(first("Bo Lind (Bank of England)") == (nil, "Bank of England"))
        XCTAssertTrue(first("Bo Lind (CTO of Acme)") == ("CTO", "Acme"))
        XCTAssertTrue(first("Bo Lind (buyer at Bank of England)") == ("buyer", "Bank of England"))
        XCTAssertTrue(first("Bo Lind (accountant for Example Ltd)") == ("accountant", "Example Ltd"))
    }

    func testBracketsWithACommaOrNeverClosed() {
        let p = PeoplePages.parseParticipants("Anna Berg (Acme, Inc), Pere Soler")
        XCTAssertEqual(p.map(\.name), ["Anna Berg", "Pere Soler"])
        XCTAssertEqual(p.first?.organisation, "Acme, Inc")
        let open = PeoplePages.parseParticipants("Anna Berg (Acme, Pere Soler")
        XCTAssertEqual(open.map(\.name), ["Anna Berg", "Pere Soler"])
        XCTAssertEqual(open.first?.organisation, "Acme")
        let at = PeoplePages.parseParticipants("Anna Berg at Acme, Pere Soler from Globex")
        XCTAssertEqual(at.map(\.name), ["Anna Berg", "Pere Soler"])
        XCTAssertEqual(at.map(\.organisation), ["Acme", "Globex"])
    }

    func testTheArticleIsNotPartOfTheRole() {
        XCTAssertEqual(SelfIntroductions.role(in: "I'm an engineer at Acme."), "engineer")
        XCTAssertEqual(SelfIntroductions.role(in: "I'm a designer."), "designer")
        XCTAssertEqual(SelfIntroductions.role(in: "Soy una directora."), "directora")
        XCTAssertEqual(SelfIntroductions.role(in: "I'm the head of platform at Acme."), "head of platform")
    }

    func testAliasesWrittenAsAListOrInSingleQuotes() throws {
        XCTAssertEqual(PeoplePages.aliases(inFrontmatter: "['Lind, Oskar', Oscar]"), ["Lind, Oskar", "Oscar"])
        XCTAssertEqual(PeoplePages.aliases(inFrontmatter: "O'Brien, \"Lind, O\""), ["O'Brien", "Lind, O"])
        XCTAssertEqual(PeoplePages.frontmatter(of: "---\nname: 'Oskar Lind'\nrole: ''\n---\n")["name"], "Oskar Lind")
        let e = try env([(b1, ["S0": "Oskar Lind"], nil), (b2, ["S0": "Oscar Lind"], nil)])
        try write(e, "Oskar Lind.md", "---\ntype: person\nname: Oskar Lind\naliases:\n  - Oscar Lind\n  - \"Lind, O\"\nrole: \n---\n# Oskar Lind\n")
        XCTAssertEqual(try update(e).created, [])
        XCTAssertTrue(try read(e, "Oskar Lind.md").contains("2 meetings"))
    }

    func testAFinderCopyDoesNotBecomeThePage() throws {
        let e = try env([(b1, ["S0": "Oskar Lind"], nil)])
        let page = "---\ntype: person\nname: Oskar Lind\nrole: \n---\n# Oskar\n"
        try write(e, "Oskar Lind.md", page); try write(e, "Oskar Lind copy.md", page)
        _ = try update(e)
        XCTAssertTrue(try read(e, "Oskar Lind.md").contains("distavo:meetings:start"))
        XCTAssertEqual(try read(e, "Oskar Lind copy.md"), page)
    }

    func testAddingAPersonDoesNotDoubleTheSeparator() {
        let k = PeoplePages.Known(name: "Petra Novak", aliases: [], role: "", organisation: "")
        XCTAssertEqual(PeoplePages.adding(k, to: "Oskar Lind,"), "Oskar Lind, Petra Novak")
        XCTAssertEqual(PeoplePages.adding(k, to: "Oskar Lind ; "), "Oskar Lind, Petra Novak")
        XCTAssertEqual(PeoplePages.adding(k, to: " , "), "Petra Novak")
    }

    func testAPageNamedInLowerCaseStillGetsItsMeetings() throws {
        let e = try env([(b1, ["S0": "Oskar Lind"], nil)])
        try write(e, "oskar.md", "---\ntype: person\nname: oskar lind\n---\nmine\n")
        let s = try update(e)
        XCTAssertEqual(s.created, [])
        XCTAssertTrue(try read(e, "oskar.md").contains("distavo:meetings:start"))
    }

    func testAWindowsPageKeepsItsLineEndingsAndIsRecognised() throws {
        let e = try env([(b1, ["S0": "Oskar Lind"], "Other participants: Oskar Lind (Acme) - buyer")])
        try write(e, "Oskar Lind.md", "\u{FEFF}---\r\ntype: person\r\nname: Oskar Lind\r\nrole: \r\norganisation: \r\n---\r\nmine\r\n")
        XCTAssertEqual(try update(e).created, [])
        let text = try read(e, "Oskar Lind.md")
        XCTAssertTrue(text.contains("role: buyer\r\n") && text.contains("organisation: Acme\r\n") && text.contains("mine\r\n"), text)
        XCTAssertFalse(text.replacingOccurrences(of: "\r\n", with: "").contains("\n"), "mixed line endings")
        XCTAssertEqual(PeoplePages.known(notesDir: e.notes).first?.role, "buyer")
        XCTAssertEqual(try update(e).unchanged, 1)   // stable on the second run
    }

    func testNamesThatDifferOnlyByAFinalDotGetTheirOwnFiles() {
        XCTAssertNotEqual(PeoplePages.fileName(for: "Anna Smith Jr."), PeoplePages.fileName(for: "Anna Smith Jr"))
        XCTAssertEqual(PeoplePages.fileName(for: ".hidden"), "hidden.md")
        XCTAssertEqual(PeoplePages.fileName(for: "..."), "Person .md")
    }

    func testLastSeenComesFromDistavosBlockOnly() throws {
        let e = try env([])
        try write(e, "Oskar Lind.md", "---\ntype: person\nname: Oskar Lind\n---\nI last seen 1999-01-01 him at a fair.\n\(PeoplePages.blockStart)\n## Meetings\nFirst seen 2026-11-01 · last seen 2026-11-18 · 2 meetings\n\(PeoplePages.blockEnd)\n")
        try write(e, "Petra Novak.md", "---\ntype: person\nname: Petra Novak\n---\nlast seen 2030-01-01 in my own words\n")
        let k = PeoplePages.known(notesDir: e.notes)
        XCTAssertEqual(k.map(\.lastSeen), ["2026-11-18", ""])
    }

    func testARoleInsideAnotherWordIsStillAdded() throws {
        let e = try env([])
        try write(e, "Oskar Lind.md", "---\ntype: person\nname: Oskar Lind\nrole: CTO\norganisation: Acme\n---\n")
        let line = PeoplePages.participants("Other participants: Oskar Lind, the director of Acme", alsoPresent: [], notesDir: e.notes)
        XCTAssertTrue(line?.contains("Oskar Lind: CTO") == true, line ?? "nil")
        XCTAssertEqual(PeoplePages.participants("Other participants: Oskar Lind (Acme) - CTO", alsoPresent: [], notesDir: e.notes),
                       "Other participants: Oskar Lind (Acme) - CTO")
    }
}

/// `_Organisations.md`: the people pages grouped by organisation. Synthetic names only.
final class PeopleOrganisationsTests: XCTestCase {
    private let zone = TimeZone(identifier: "Europe/London")!

    func testGroupsByOrganisationNewestFirst() throws {
        let root = TestTemp.root.appendingPathComponent("distavo-orgs-\(UUID().uuidString)")
        let notes = root.appendingPathComponent("notes"), work = root.appendingPathComponent("work")
        for d in [notes, work] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        func meeting(_ base: String, _ line: String) throws {
            try "# Call\n".write(to: notes.appendingPathComponent("\(base).md"), atomically: true, encoding: .utf8)
            try SpeakerHints(participants: line).save(workDir: work, base: base)
        }
        try meeting("Meeting_2026-11-10_09.00.00", "Other participants: Anna Berg (Acme) - buyer, Bo Lind (Globex), Cleo Marsh")
        try meeting("Meeting_2026-11-12_09.00.00", "Other participants: Dan Roca (ACME) - [lead] engineer, Anna Berg")
        try meeting("Meeting_2026-11-14_09.00.00", "Other participants: Bo Lind")
        _ = try PeoplePages.update(notesDir: notes, workDir: work, timeZone: zone)
        let url = PeoplePages.folder(notesDir: notes).appendingPathComponent(PeoplePages.organisationsName)
        let text = try String(contentsOf: url, encoding: .utf8)
        let headings = text.components(separatedBy: "\n").filter { $0.hasPrefix("## ") }
        XCTAssertEqual(headings, ["## Globex", "## ACME", "## No organisation yet"], text)   // Globex seen last; ACME/Acme one group
        XCTAssertTrue(text.contains("## ACME\n2 people · 2 meetings\n\n- [Anna Berg](Anna%20Berg.md) · buyer · last seen 2026-11-12\n- [Dan Roca](Dan%20Roca.md) · (lead) engineer · last seen 2026-11-12\n")
                      || text.contains("- [Dan Roca](Dan%20Roca.md) · [lead] engineer"), text)
        // Stable, and never read back as a person.
        let again = try PeoplePages.update(notesDir: notes, workDir: work, timeZone: zone)
        XCTAssertEqual(again.created + again.updated, [])
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), text)
        XCTAssertEqual(PeoplePages.known(notesDir: notes).count, 4)
    }
}

final class PeopleIndexKeepsPagesTests: XCTestCase {
    func testAPersonWhoseOnlyNoteWasDeletedStaysListed() throws {
        let zone = TimeZone(identifier: "Europe/London")!
        let root = TestTemp.root.appendingPathComponent("distavo-keep-\(UUID().uuidString)")
        let notes = root.appendingPathComponent("notes"), work = root.appendingPathComponent("work")
        for d in [notes, work] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        for (base, name) in [("Meeting_2026-11-10_09.00.00", "Oskar Lind"), ("Meeting_2026-11-12_09.00.00", "Petra Novak")] {
            try "# Call\n".write(to: notes.appendingPathComponent("\(base).md"), atomically: true, encoding: .utf8)
            try SpeakerHints(participants: "Other participants: \(name) (Acme)").save(workDir: work, base: base)
        }
        _ = try PeoplePages.update(notesDir: notes, workDir: work, timeZone: zone)
        let people = PeoplePages.folder(notesDir: notes)
        let page = people.appendingPathComponent("Oskar Lind.md")
        let before = try String(contentsOf: page, encoding: .utf8)
        try FileManager.default.removeItem(at: notes.appendingPathComponent("Meeting_2026-11-10_09.00.00.md"))
        let s = try PeoplePages.update(notesDir: notes, workDir: work, timeZone: zone)
        XCTAssertEqual(s.created + s.updated, [])
        XCTAssertEqual(try String(contentsOf: page, encoding: .utf8), before, "the page itself is left as it was")
        let index = try String(contentsOf: s.index, encoding: .utf8)
        XCTAssertTrue(index.contains("| [Oskar Lind](Oskar%20Lind.md) |  | Acme |  | 2026-11-10 |"), index)
        XCTAssertTrue(index.range(of: "Petra Novak")!.lowerBound < index.range(of: "Oskar Lind")!.lowerBound)
        let orgs = try String(contentsOf: people.appendingPathComponent(PeoplePages.organisationsName), encoding: .utf8)
        XCTAssertTrue(orgs.contains("- [Oskar Lind](Oskar%20Lind.md) · last seen 2026-11-10"), orgs)
        XCTAssertEqual(try PeoplePages.update(notesDir: notes, workDir: work, timeZone: zone).updated, [])
    }
}
