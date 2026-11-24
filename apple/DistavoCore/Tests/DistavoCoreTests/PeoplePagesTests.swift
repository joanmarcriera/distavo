import XCTest
@testable import DistavoCore

/// `PeoplePages`: one page per person the owner named, in notes/people/. Synthetic names only.
final class PeoplePagesTests: XCTestCase {
    private let zone = TimeZone(identifier: "Europe/London")!

    private func fixture() throws -> (notes: URL, work: URL) {
        let root = TestTemp.root.appendingPathComponent("distavo-people-\(UUID().uuidString)")
        let notes = root.appendingPathComponent("notes"), work = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        func note(_ base: String, _ title: String) throws {
            try "# \(title)\n\nSPEAKER_00 and Oskar talked.\n".write(to: notes.appendingPathComponent("\(base).md"), atomically: true, encoding: .utf8)
        }
        try note("Meeting_2026-11-18_09.00.00", "Garden planning call")
        try note("Meeting_2026-11-19_14.30.00", "Supplier call")
        try note("Meeting_2026-11-20_10.00.00", "Nobody named here")
        // 18th: Oskar spoke (renamed speaker); Petra only listed.
        try SpeakerNames(names: ["SPEAKER_00": "Dana Owner", "SPEAKER_01": "Oskar Lind"]).encoded()
            .write(to: SpeakerNames.url(workDir: work, base: "Meeting_2026-11-18_09.00.00"))
        try SpeakerHints(participants: "Petra Novak (Acme Cooling) - buyer; Dana Owner (me)")
            .save(workDir: work, base: "Meeting_2026-11-18_09.00.00")
        // 19th: a misspelling of Oskar, one label left unnamed.
        try SpeakerNames(names: ["SPEAKER_00": "Oscar Lind", "SPEAKER_01": "SPEAKER_01"]).encoded()
            .write(to: SpeakerNames.url(workDir: work, base: "Meeting_2026-11-19_14.30.00"))
        return (notes, work)
    }

    private let glossary = NameGlossary.parse("Oskar Lind: Oscar Lind\nAcme Cooling\n")

    private func page(_ notes: URL, _ name: String) throws -> String {
        try String(contentsOf: PeoplePages.folder(notesDir: notes).appendingPathComponent(name), encoding: .utf8)
    }

    func testParticipantsLine() {
        let p = PeoplePages.parseParticipants("Edward (Cambridge University) - interviewer; Annika for WWT, Marc (me), two engineers\nBo (accountant for Example Ltd)")
        XCTAssertEqual(p.map(\.name), ["Edward", "Annika", "Bo"])
        XCTAssertEqual(p.map(\.organisation), ["Cambridge University", "WWT", "Example Ltd"])
        XCTAssertEqual(p.map(\.role), ["interviewer", nil, "accountant"])
    }

    func testTheStoredParticipantsLineNamesOnlyTheOthers() {
        func names(_ t: String) -> [String] { PeoplePages.parseParticipants(t).map(\.name) }
        XCTAssertEqual(names("Other participants: Anna (Acme) - buyer, Pere"), ["Anna", "Pere"])
        XCTAssertEqual(names("Dana (Dana, me): candidate. Other participants: Anna (Acme) - buyer, Pere"), ["Anna", "Pere"])
        XCTAssertEqual(names("In-person meeting recorded with one microphone. Other participants: Anna, Pere"), ["Anna", "Pere"])
        XCTAssertEqual(names("Other participants: The CFO, Someone from procurement, Two engineers from Acme, Anna"), ["Anna"])
        XCTAssertEqual(PeoplePages.parseParticipants("Other participants: Anna (Acme) - buyer").first?.organisation, "Acme")
    }

    func testNamesThatAreNotPeople() {
        for bad in ["SPEAKER_01", "Speaker 2", "unknown", "Unknown", "me", "a very long description of five words", "A/B"] {
            XCTAssertFalse(PeoplePages.isPersonName(bad), bad)
        }
        XCTAssertTrue(PeoplePages.isPersonName("Àngels Puig"))
    }

    func testCreatesPagesFromConfirmedNamesOnly() throws {
        let (notes, work) = try fixture()
        let s = try PeoplePages.update(notesDir: notes, workDir: work, ownerName: "Dana Owner", glossary: glossary, timeZone: zone)
        XCTAssertEqual(s.created, ["Oskar Lind", "Petra Novak"])   // not the owner, not a label, not the glossary term
        let oskar = try page(notes, "Oskar Lind.md")
        XCTAssertTrue(oskar.hasPrefix("---\ntype: person\nname: Oskar Lind\naliases: [Oscar Lind]\nrole: \norganisation: \nlinkedin: \n---\n# Oskar Lind\n"))
        XCTAssertTrue(oskar.contains("First seen 2026-11-18 · last seen 2026-11-19 · 2 meetings"))
        XCTAssertTrue(oskar.contains("- 2026-11-19 · [Supplier call](../Meeting_2026-11-19_14.30.00.md) · spoke"))
        XCTAssertTrue(oskar.contains("[Find on LinkedIn](https://www.linkedin.com/search/results/people/?keywords=Oskar%20Lind)"))
        let petra = try page(notes, "Petra Novak.md")
        XCTAssertTrue(petra.contains("role: buyer\norganisation: Acme Cooling\n"))
        XCTAssertTrue(petra.contains("· [Garden planning call](../Meeting_2026-11-18_09.00.00.md) · listed"))
        XCTAssertTrue(petra.contains("keywords=Petra%20Novak%20Acme%20Cooling"))
        let index = try String(contentsOf: s.index, encoding: .utf8)
        XCTAssertTrue(index.contains("| [Oskar Lind](Oskar%20Lind.md) |  |  | 2 | 2026-11-19 |"))
        XCTAssertTrue(index.contains("| [Petra Novak](Petra%20Novak.md) | buyer | Acme Cooling | 1 | 2026-11-18 |"))
        // Every link in a page points at a note that exists.
        for target in DayLog.linkTargets(in: oskar) where target.hasPrefix("../") {
            let file = target.dropFirst(3).removingPercentEncoding!
            XCTAssertTrue(FileManager.default.fileExists(atPath: notes.appendingPathComponent(file).path), target)
        }
    }

    func testSecondRunChangesNothing() throws {
        let (notes, work) = try fixture()
        try PeoplePages.update(notesDir: notes, workDir: work, ownerName: "Dana Owner", glossary: glossary, timeZone: zone)
        let before = try page(notes, "Oskar Lind.md")
        let s = try PeoplePages.update(notesDir: notes, workDir: work, ownerName: "Dana Owner", glossary: glossary, timeZone: zone)
        XCTAssertEqual(s.created, []); XCTAssertEqual(s.updated, []); XCTAssertEqual(s.unchanged, 2)
        XCTAssertEqual(try page(notes, "Oskar Lind.md"), before)
    }

    func testOwnersEditsSurviveAndOnlyTheBlockMoves() throws {
        let (notes, work) = try fixture()
        try PeoplePages.update(notesDir: notes, workDir: work, ownerName: "Dana Owner", glossary: glossary, timeZone: zone)
        let file = PeoplePages.folder(notesDir: notes).appendingPathComponent("Petra Novak.md")
        var text = try String(contentsOf: file, encoding: .utf8)
        text = text.replacingOccurrences(of: "role: buyer", with: "role: head of purchasing")
            .replacingOccurrences(of: "linkedin: ", with: "linkedin: https://www.linkedin.com/in/example")
            .replacingOccurrences(of: "# Petra Novak\n\n", with: "# Petra Novak\n\nMet at the trade fair. Prefers email.\n\n")
        text += "\nMy notes below the block stay too.\n"
        try text.write(to: file, atomically: true, encoding: .utf8)
        // A new meeting names her as a speaker.
        try SpeakerNames(names: ["SPEAKER_00": "Petra Novak"]).encoded()
            .write(to: SpeakerNames.url(workDir: work, base: "Meeting_2026-11-20_10.00.00"))
        let s = try PeoplePages.update(notesDir: notes, workDir: work, ownerName: "Dana Owner", glossary: glossary, timeZone: zone)
        XCTAssertEqual(s.updated, ["Petra Novak"])
        let after = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(after.contains("role: head of purchasing\n"))
        XCTAssertTrue(after.contains("linkedin: https://www.linkedin.com/in/example\n"))
        XCTAssertTrue(after.contains("Met at the trade fair. Prefers email."))
        XCTAssertTrue(after.hasSuffix("\nMy notes below the block stay too.\n"))
        XCTAssertTrue(after.contains("last seen 2026-11-20 · 2 meetings"))
        XCTAssertFalse(after.contains("Find on LinkedIn"))   // the address is filled in
        XCTAssertEqual(after.components(separatedBy: PeoplePages.blockEnd).count, 2)   // one block, not two
    }

    func testAliasOnAPageMergesAnotherSpelling() throws {
        let (notes, work) = try fixture()
        try PeoplePages.update(notesDir: notes, workDir: work, ownerName: "Dana Owner", timeZone: zone)   // no glossary: two Oskars
        let dir = PeoplePages.folder(notesDir: notes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Oscar Lind.md").path))
        try FileManager.default.removeItem(at: dir.appendingPathComponent("Oscar Lind.md"))
        let file = dir.appendingPathComponent("Oskar Lind.md")
        try String(contentsOf: file, encoding: .utf8).replacingOccurrences(of: "aliases: []", with: "aliases: [Oscar Lind]")
            .write(to: file, atomically: true, encoding: .utf8)
        let s = try PeoplePages.update(notesDir: notes, workDir: work, ownerName: "Dana Owner", timeZone: zone)
        XCTAssertEqual(s.created, [])
        XCTAssertTrue(try page(notes, "Oskar Lind.md").contains("· 2 meetings"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Oscar Lind.md").path))
    }

    func testDeletedMarkersGetTheBlockAppended() throws {
        let (notes, work) = try fixture()
        let dir = PeoplePages.folder(notesDir: notes)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "---\ntype: person\nname: Oskar Lind\n---\n# Oskar Lind\n\nHand-written page.\n"
            .write(to: dir.appendingPathComponent("Oskar Lind.md"), atomically: true, encoding: .utf8)
        try PeoplePages.update(notesDir: notes, workDir: work, ownerName: "Dana Owner", glossary: glossary, timeZone: zone)
        let text = try page(notes, "Oskar Lind.md")
        XCTAssertTrue(text.hasPrefix("---\ntype: person\nname: Oskar Lind\n---\n# Oskar Lind\n\nHand-written page.\n\n" + PeoplePages.blockStart))
        XCTAssertTrue(text.hasSuffix(PeoplePages.blockEnd + "\n"))
    }

    func testPeoplePagesStayOutOfTheNotesList() throws {
        let (notes, work) = try fixture()
        try PeoplePages.update(notesDir: notes, workDir: work, ownerName: "Dana Owner", glossary: glossary, timeZone: zone)
        XCTAssertEqual(NotesLibrary.scan(notesDir: notes, workDir: work, timeZone: zone).count, 3)
    }

    func testNobodyNamedStillWritesAnIndexThatSaysSo() throws {
        let root = TestTemp.root.appendingPathComponent("distavo-people-empty-\(UUID().uuidString)")
        let notes = root.appendingPathComponent("notes"), work = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        let s = try PeoplePages.update(notesDir: notes, workDir: work, timeZone: zone)
        XCTAssertTrue(try String(contentsOf: s.index, encoding: .utf8).contains("Nobody yet."))
    }

    func testQuotedFrontmatterRoundTrips() {
        XCTAssertEqual(PeoplePages.quote("Lind, Oskar"), "\"Lind, Oskar\"")
        XCTAssertEqual(PeoplePages.unquote(PeoplePages.quote("He said \"hi\": ok")), "He said \"hi\": ok")
        XCTAssertEqual(PeoplePages.aliases(inFrontmatter: "[Jordon, \"Ellis, J\"]"), ["Jordon", "Ellis, J"])
    }
}

/// Known people in the summary prompt (`summarise.known_people`).
final class KnownPeopleTests: XCTestCase {
    private func notes(_ pages: [String: String]) throws -> URL {
        let notes = TestTemp.root.appendingPathComponent("distavo-known-\(UUID().uuidString)")
        let dir = PeoplePages.folder(notesDir: notes)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, text) in pages { try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        return notes
    }
    private func page(_ name: String, aliases: String = "", role: String = "", org: String = "") -> String {
        "---\ntype: person\nname: \(name)\naliases: [\(aliases)]\nrole: \(role)\norganisation: \(org)\nlinkedin: \n---\n# \(name)\n"
    }

    func testOffByDefaultOldConfigsAndFreshInstalls() throws {
        XCTAssertFalse(Config().summarise.knownPeople)
        let old = try JSONDecoder().decode(Config.self, from: Data(#"{"summarise":{"model":"x"}}"#.utf8))
        XCTAssertFalse(old.summarise.knownPeople)
        XCTAssertFalse(Config.recommendedForThisMac().summarise.knownPeople)
    }

    func testParticipantsGainWhatThePagesSay() throws {
        let dir = try notes([
            "Petra Novak.md": page("Petra Novak", aliases: "Petra N", role: "head of purchasing", org: "Acme Cooling"),
            "Oskar Lind.md": page("Oskar Lind", org: "Lind GmbH"),
            "Empty Person.md": page("Empty Person"),
            "_People.md": "---\ntype: people-index\n---\n",
        ])
        let out = PeoplePages.participants("Petra N - buyer; Empty Person, Someone Else", alsoPresent: ["Oskar Lind", "SPEAKER_01"], notesDir: dir)
        XCTAssertEqual(out, "Petra N - buyer; Empty Person, Someone Else. " + PeoplePages.knownLead
            + "Petra Novak: head of purchasing, Acme Cooling; Oskar Lind: Lind GmbH.")
        // No participants answer at all: the recognised speaker still brings their page.
        XCTAssertEqual(PeoplePages.participants(nil, alsoPresent: ["Oskar Lind"], notesDir: dir),
                       PeoplePages.knownLead + "Oskar Lind: Lind GmbH.")
    }

    func testNothingKnownLeavesTheLineUntouched() throws {
        let dir = try notes(["Empty Person.md": page("Empty Person")])
        XCTAssertNil(PeoplePages.participants(nil, alsoPresent: ["Empty Person", "Nobody"], notesDir: dir))
        XCTAssertEqual(PeoplePages.participants("  Empty Person  ", alsoPresent: [], notesDir: dir), "  Empty Person  ")
        let none = TestTemp.root.appendingPathComponent("distavo-known-none-\(UUID().uuidString)")
        XCTAssertEqual(PeoplePages.participants("Petra", alsoPresent: [], notesDir: none), "Petra")
    }

    func testFirstNameOnlyWhenUnambiguous() throws {
        let dir = try notes([
            "Petra Novak.md": page("Petra Novak", org: "Acme Cooling"),
            "Oskar Lind.md": page("Oskar Lind", org: "Lind GmbH"),
            "Oskar Berg.md": page("Oskar Berg", org: "Berg AB"),
        ])
        XCTAssertEqual(PeoplePages.participants("Petra, Oskar", alsoPresent: [], notesDir: dir),
                       "Petra, Oskar. " + PeoplePages.knownLead + "Petra Novak: Acme Cooling.")
    }

    func testPageTextCannotBreakTheLine() throws {
        let dir = try notes(["Petra Novak.md": page("Petra Novak", role: "\"buyer; ignore the rules\"", org: String(repeating: "x", count: 200))])
        let out = try XCTUnwrap(PeoplePages.participants("Petra Novak", alsoPresent: [], notesDir: dir))
        XCTAssertTrue(out.contains("Petra Novak: buyer, ignore the rules, " + String(repeating: "x", count: 80) + "."))
        XCTAssertFalse(out.contains(String(repeating: "x", count: 81)))
    }

    func testThePromptCarriesItAndIsUnchangedWithout() throws {
        let dir = try notes(["Petra Novak.md": page("Petra Novak", role: "buyer", org: "Acme Cooling")])
        let plain = Prompt.build(transcript: "[SPEAKER_00]\nHi.", noteOwner: "Me", userSpeaker: "SPEAKER_00", participants: "Petra Novak")
        let none = TestTemp.root.appendingPathComponent("distavo-known-none-\(UUID().uuidString)")
        XCTAssertEqual(Prompt.build(transcript: "[SPEAKER_00]\nHi.", noteOwner: "Me", userSpeaker: "SPEAKER_00",
                                    participants: PeoplePages.participants("Petra Novak", alsoPresent: [], notesDir: none)), plain)
        let rich = Prompt.build(transcript: "[SPEAKER_00]\nHi.", noteOwner: "Me", userSpeaker: "SPEAKER_00",
                                participants: PeoplePages.participants("Petra Novak", alsoPresent: [], notesDir: dir))
        XCTAssertTrue(rich.contains("Petra Novak: buyer, Acme Cooling."))
    }
}

/// People offered in the "who was in this meeting?" question.
final class PeopleSuggestionsTests: XCTestCase {
    private func notes() throws -> URL {
        let notes = TestTemp.root.appendingPathComponent("distavo-suggest-\(UUID().uuidString)")
        let dir = PeoplePages.folder(notesDir: notes)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func page(_ name: String, aliases: String = "", role: String = "", org: String = "", last: String?) throws {
            var text = "---\ntype: person\nname: \(name)\naliases: [\(aliases)]\nrole: \(role)\norganisation: \(org)\nlinkedin: \n---\n# \(name)\n"
            if let last { text += "\n\(PeoplePages.blockStart)\n## Meetings\nFirst seen 2026-01-01 · last seen \(last) · 2 meetings\n\(PeoplePages.blockEnd)\n" }
            try text.write(to: dir.appendingPathComponent("\(name).md"), atomically: true, encoding: .utf8)
        }
        try page("Petra Novak", aliases: "Petra N", role: "head of purchasing, EMEA", org: "Acme Cooling (UK)", last: "2026-11-18")
        try page("Oskar Lind", last: "2026-11-20")
        try page("Anna Berg", org: "Berg AB", last: nil)
        try "---\ntype: people-index\n---\n".write(to: dir.appendingPathComponent("_People.md"), atomically: true, encoding: .utf8)
        return notes
    }

    func testMostRecentlySeenFirstAndTheEntryText() throws {
        let s = PeoplePages.suggestions(notesDir: try notes())
        XCTAssertEqual(s.map(\.name), ["Oskar Lind", "Petra Novak", "Anna Berg"])
        XCTAssertEqual(s.map(\.participantsEntry),
                       ["Oskar Lind", "Petra Novak (Acme Cooling UK) - head of purchasing EMEA", "Anna Berg (Berg AB)"])
        XCTAssertEqual(PeoplePages.suggestions(notesDir: try notes(), limit: 1).count, 1)
        XCTAssertTrue(PeoplePages.suggestions(notesDir: TestTemp.root.appendingPathComponent("none-\(UUID().uuidString)")).isEmpty)
    }

    func testAddingAppendsOnceAndParsesBackToOnePerson() throws {
        let s = PeoplePages.suggestions(notesDir: try notes())
        let petra = s[1]
        XCTAssertEqual(PeoplePages.adding(petra, to: ""), petra.participantsEntry)
        let line = PeoplePages.adding(petra, to: "Oskar Lind")
        XCTAssertEqual(line, "Oskar Lind, Petra Novak (Acme Cooling UK) - head of purchasing EMEA")
        XCTAssertEqual(PeoplePages.adding(petra, to: line), line, "already there")
        XCTAssertEqual(PeoplePages.adding(petra, to: "Petra N - buyer"), "Petra N - buyer", "an alias counts as already there")
        // The line reads back as two people, and the speaker count follows it.
        let parsed = PeoplePages.parseParticipants(line)
        XCTAssertEqual(parsed.map(\.name), ["Oskar Lind", "Petra Novak"])
        XCTAssertEqual(parsed[1].organisation, "Acme Cooling UK")
        XCTAssertEqual(parsed[1].role, "head of purchasing EMEA")
    }

    func testKnownPeopleDoNotRepeatWhatWasPicked() throws {
        let dir = try notes()
        let petra = PeoplePages.suggestions(notesDir: dir)[1]
        let line = PeoplePages.adding(petra, to: "")
        // The picked entry flattened the page's punctuation, so the page's exact text is still new information.
        let out = try XCTUnwrap(PeoplePages.participants("Anna Berg (Berg AB)", alsoPresent: [], notesDir: dir))
        XCTAssertEqual(out, "Anna Berg (Berg AB)", "the organisation is already in the line")
        XCTAssertNotNil(PeoplePages.participants(line, alsoPresent: [], notesDir: dir))
    }
}

/// A people page whose markers the owner damaged never loses the owner's text.
final class PeoplePageMarkerTests: XCTestCase {
    private let zone = TimeZone(identifier: "Europe/London")!
    private var person: PeoplePages.Person {
        var p = PeoplePages.Person(name: "Oskar Lind")
        p.meetings = [.init(base: "Meeting_2026-11-18_09.00.00", date: Date(timeIntervalSince1970: 1_795_000_000),
                            title: "Call", notePath: URL(fileURLWithPath: "/tmp/notes/Meeting_2026-11-18_09.00.00.md"), spoke: true)]
        return p
    }
    private func starts(_ s: String) -> Int { s.components(separatedBy: "<!-- distavo:meetings:start").count - 1 }
    private func ends(_ s: String) -> Int { s.components(separatedBy: PeoplePages.blockEnd).count - 1 }

    func testMissingEndMarkerKeepsEveryLineOfTheOwner() {
        let fresh = PeoplePages.newPage(person, timeZone: zone)
        // The owner deleted the end marker and wrote below the block.
        let damaged = fresh.replacingOccurrences(of: PeoplePages.blockEnd + "\n", with: "") + "\nMy own notes about Oskar.\nSecond line.\n"
        let once = PeoplePages.refreshed(page: damaged, with: person, timeZone: zone)
        let twice = PeoplePages.refreshed(page: once, with: person, timeZone: zone)
        for page in [once, twice] {
            XCTAssertTrue(page.contains("My own notes about Oskar.\nSecond line."), page)
            XCTAssertEqual(starts(page), 1, page)
            XCTAssertEqual(ends(page), 1, page)
        }
        XCTAssertEqual(once, twice)   // settles after one update
    }

    func testTwoStartMarkersOnlyTheCompleteBlockIsReplaced() {
        let fresh = PeoplePages.newPage(person, timeZone: zone)
        let page = fresh.replacingOccurrences(of: "# Oskar Lind\n", with: "# Oskar Lind\n\n\(PeoplePages.blockStart)\nText I wrote between the markers.\n")
        let out = PeoplePages.refreshed(page: page, with: person, timeZone: zone)
        XCTAssertTrue(out.contains("Text I wrote between the markers."), out)
        XCTAssertEqual(starts(out), 1, out)
        XCTAssertEqual(ends(out), 1, out)
        XCTAssertEqual(PeoplePages.refreshed(page: out, with: person, timeZone: zone), out)
    }

    func testAnUndamagedPageIsUnchanged() {
        let fresh = PeoplePages.newPage(person, timeZone: zone)
        XCTAssertEqual(PeoplePages.refreshed(page: fresh, with: person, timeZone: zone), fresh)
        let edited = fresh.replacingOccurrences(of: "# Oskar Lind\n", with: "# Oskar Lind\n\nMet at the fair.\n") + "\nFooter of mine.\n"
        XCTAssertEqual(PeoplePages.refreshed(page: edited, with: person, timeZone: zone), edited)
    }
}
