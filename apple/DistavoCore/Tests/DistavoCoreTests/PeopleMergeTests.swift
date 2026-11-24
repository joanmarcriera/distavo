import XCTest
@testable import DistavoCore

/// One person ended up as two people pages: merge them, and undo the merge. Synthetic names only.
final class PeopleMergeTests: XCTestCase {
    private let zone = TimeZone(identifier: "Europe/London")!
    private typealias Env = (notes: URL, work: URL, people: URL)

    /// One note per (base, renamed speakers, participants answer).
    private func env(_ meetings: [(String, [String: String], String?)]) throws -> Env {
        let root = TestTemp.root.appendingPathComponent("distavo-peoplemerge-\(UUID().uuidString)")
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
    private let b1 = "Meeting_2026-11-18_09.00.00", b2 = "Meeting_2026-11-19_14.30.00", b3 = "Meeting_2026-11-20_10.00.00"
    @discardableResult
    private func update(_ e: Env) throws -> PeoplePages.Summary {
        try PeoplePages.update(notesDir: e.notes, workDir: e.work, ownerName: "Dana Owner", timeZone: zone)
    }
    private func read(_ e: Env, _ file: String) throws -> String {
        try String(contentsOf: e.people.appendingPathComponent(file), encoding: .utf8)
    }
    private func write(_ e: Env, _ file: String, _ text: String) throws {
        try text.write(to: e.people.appendingPathComponent(file), atomically: true, encoding: .utf8)
    }
    private func exists(_ e: Env, _ file: String) -> Bool {
        FileManager.default.fileExists(atPath: e.people.appendingPathComponent(file).path)
    }
    private func two() throws -> Env {
        let e = try env([(b1, ["SPEAKER_01": "Petra Novak"], nil), (b2, ["SPEAKER_00": "Petra N"], nil),
                         (b3, ["SPEAKER_00": "Oskar Lind"], nil)])
        try update(e)
        return e
    }

    func testMergeMakesOnePageWithTheMeetingsOfBoth() throws {
        let e = try two()
        let out = try PeopleMerge.merge("Petra N", into: "Petra Novak", notesDir: e.notes)
        XCTAssertEqual(out, .init(kept: "Petra Novak", other: "Petra N", aliases: ["Petra N"], notes: false))
        XCTAssertFalse(exists(e, "Petra N.md"))
        XCTAssertTrue(exists(e, "_merged-Petra N.md"))
        let s = try update(e)
        XCTAssertEqual(s.created, [], "the merged spelling must not get a page again")
        let page = try read(e, "Petra Novak.md")
        XCTAssertTrue(page.contains("aliases: [Petra N]"))
        XCTAssertTrue(page.contains("2 meetings"))
        XCTAssertFalse(try read(e, "_People.md").contains("Petra N]"), "the set-aside page is not a person")
        XCTAssertEqual(PeoplePages.known(notesDir: e.notes).map(\.name), ["Oskar Lind", "Petra Novak"])
    }

    func testTheOwnersTextOfTheOtherPageIsCopiedAndThePageKeptByteForByte() throws {
        let e = try two()
        var other = try read(e, "Petra N.md")
        other = other.replacingOccurrences(of: "role: ", with: "role: buyer").replacingOccurrences(of: "linkedin: ", with: "linkedin: https://example.com/in/petra")
            .replacingOccurrences(of: "# Petra N\n", with: "# Petra N\n\nMet at the fair.\nLikes short calls.\n")
        try write(e, "Petra N.md", other)
        let out = try PeopleMerge.merge("Petra N", into: "Petra Novak", notesDir: e.notes)
        XCTAssertTrue(out.notes)
        XCTAssertEqual(try read(e, "_merged-Petra N.md"), other)
        let page = try read(e, "Petra Novak.md")
        XCTAssertTrue(page.contains("## From the page of Petra N (merged)\nRole: buyer · LinkedIn: https://example.com/in/petra\n\nMet at the fair.\nLikes short calls.\n"))
        // Above the block Distavo rewrites, so the next update keeps it.
        XCTAssertLessThan(page.range(of: "Met at the fair.")!.lowerBound, page.range(of: "<!-- distavo:meetings:start")!.lowerBound)
        try update(e)
        XCTAssertTrue(try read(e, "Petra Novak.md").contains("Met at the fair.\nLikes short calls."))
        XCTAssertFalse(try read(e, "Petra Novak.md").contains("recognised by voice"))
    }

    func testSeparateIsTheExactUndo() throws {
        let e = try two()
        try write(e, "Petra N.md", try read(e, "Petra N.md").replacingOccurrences(of: "# Petra N\n", with: "# Petra N\n\nHer own line.\n"))
        let keptBefore = try read(e, "Petra Novak.md"), otherBefore = try read(e, "Petra N.md")
        try PeopleMerge.merge("Petra N", into: "Petra Novak", notesDir: e.notes)
        XCTAssertEqual(PeopleMerge.setAside(notesDir: e.notes).map { [$0.name, $0.into ?? "-"] }, [["Petra N", "Petra Novak"]])
        let out = try PeopleMerge.separate("Petra N", notesDir: e.notes)
        XCTAssertEqual(out, .init(kept: "Petra Novak", other: "Petra N", aliases: ["Petra N"], notes: true))
        XCTAssertEqual(try read(e, "Petra N.md"), otherBefore)
        XCTAssertEqual(try read(e, "Petra Novak.md").replacingOccurrences(of: "aliases: []", with: "aliases: []"), keptBefore)
        XCTAssertEqual(PeopleMerge.setAside(notesDir: e.notes).count, 0)
        try update(e)
        XCTAssertTrue(try read(e, "Petra Novak.md").contains("1 meeting"))
        XCTAssertTrue(try read(e, "Petra N.md").contains("1 meeting"))
    }

    func testSeparateAfterAnUpdateAndTheOwnersEditsKeepsWhatTheOwnerWrote() throws {
        let e = try two()
        try write(e, "Petra N.md", try read(e, "Petra N.md").replacingOccurrences(of: "# Petra N\n", with: "# Petra N\n\nHer own line.\n"))
        try PeopleMerge.merge("Petra N", into: "Petra Novak", notesDir: e.notes)
        try update(e)
        // The owner edits the copied section and adds a line and an alias of their own.
        var page = try read(e, "Petra Novak.md")
        page = page.replacingOccurrences(of: "Her own line.", with: "Her own line, corrected.")
            .replacingOccurrences(of: "aliases: [Petra N]", with: "aliases: [Petra N, Petrushka]")
            .replacingOccurrences(of: "# Petra Novak\n", with: "# Petra Novak\n\nMINE.\n")
        try write(e, "Petra Novak.md", page)
        let out = try PeopleMerge.separate("Petra N", notesDir: e.notes)
        XCTAssertFalse(out.notes, "an edited section is the owner's now")
        let after = try read(e, "Petra Novak.md")
        XCTAssertTrue(after.contains("aliases: [Petrushka]"))
        XCTAssertTrue(after.contains("MINE."))
        XCTAssertTrue(after.contains("Her own line, corrected."))
        try update(e)
        XCTAssertTrue(try read(e, "Petra Novak.md").contains("1 meeting"))
    }

    func testAliasesOfTheOtherPageComeAlongInEveryFrontmatterForm() throws {
        let e = try two()
        try write(e, "Petra N.md", try read(e, "Petra N.md").replacingOccurrences(of: "aliases: []", with: "aliases:\n  - Petra\n  - \"Novak, P\""))
        try write(e, "Petra Novak.md", try read(e, "Petra Novak.md").replacingOccurrences(of: "aliases: []", with: "aliases:\n  - P. Novak"))
        let kept = try read(e, "Petra Novak.md")
        let out = try PeopleMerge.merge("petra n", into: "PETRA NOVAK", notesDir: e.notes)
        XCTAssertEqual(out.aliases, ["Petra N", "Petra", "Novak, P"])
        let page = try read(e, "Petra Novak.md")
        XCTAssertEqual(PeoplePages.aliases(inFrontmatter: PeoplePages.frontmatter(of: page)["aliases"] ?? ""),
                       ["P. Novak", "Petra N", "Petra", "Novak, P"])
        XCTAssertTrue(page.contains("aliases:\n  - P. Novak\n  - Petra N\n  - Petra\n  - \"Novak, P\"\nrole:"), "a list stays a list: \(page)")
        try PeopleMerge.separate("Petra N", notesDir: e.notes)
        XCTAssertEqual(try read(e, "Petra Novak.md"), kept, "the undo is exact for a list too")
    }

    func testWindowsLineEndingsAreKept() throws {
        let e = try two()
        try write(e, "Petra Novak.md", try read(e, "Petra Novak.md").replacingOccurrences(of: "\n", with: "\r\n"))
        try write(e, "Petra N.md", try read(e, "Petra N.md").replacingOccurrences(of: "# Petra N\n", with: "# Petra N\n\nA line.\n"))
        let before = try read(e, "Petra Novak.md")
        try PeopleMerge.merge("Petra N", into: "Petra Novak", notesDir: e.notes)
        let merged = try read(e, "Petra Novak.md")
        XCTAssertFalse(merged.replacingOccurrences(of: "\r\n", with: "").contains("\n"), "every line still ends \\r\\n")
        XCTAssertTrue(merged.contains("A line.\r\n"))
        try PeopleMerge.separate("Petra N", notesDir: e.notes)
        XCTAssertEqual(try read(e, "Petra Novak.md"), before)
    }

    func testMergingAgainAfterAnInterruptedMergeCopiesNothingTwice() throws {
        let e = try two()
        try write(e, "Petra N.md", try read(e, "Petra N.md").replacingOccurrences(of: "# Petra N\n", with: "# Petra N\n\nA line.\n"))
        let other = try read(e, "Petra N.md")
        try PeopleMerge.merge("Petra N", into: "Petra Novak", notesDir: e.notes)
        let once = try read(e, "Petra Novak.md")
        // The move never happened: the other page is back where it was.
        try FileManager.default.moveItem(at: e.people.appendingPathComponent("_merged-Petra N.md"), to: e.people.appendingPathComponent("Petra N.md"))
        let out = try PeopleMerge.merge("Petra N", into: "Petra Novak", notesDir: e.notes)
        XCTAssertEqual(out.aliases, [])
        XCTAssertEqual(try read(e, "Petra Novak.md"), once)
        XCTAssertEqual(try read(e, "_merged-Petra N.md"), other)
    }

    func testRefusals() throws {
        let e = try two()
        XCTAssertThrowsError(try PeopleMerge.merge("Petra Novak", into: "petra novak", notesDir: e.notes)) { XCTAssertEqual($0 as? PeopleMerge.Failure, .samePerson) }
        XCTAssertThrowsError(try PeopleMerge.merge("Nobody Here", into: "Petra Novak", notesDir: e.notes)) { XCTAssertEqual($0 as? PeopleMerge.Failure, .noPage("Nobody Here")) }
        XCTAssertThrowsError(try PeopleMerge.merge("Petra N", into: "Nobody Here", notesDir: e.notes)) { XCTAssertEqual($0 as? PeopleMerge.Failure, .noPage("Nobody Here")) }
        XCTAssertThrowsError(try PeopleMerge.separate("Petra N", notesDir: e.notes)) { XCTAssertEqual($0 as? PeopleMerge.Failure, .notSetAside("Petra N")) }
        // A set-aside page is never a page to merge with.
        try PeopleMerge.merge("Petra N", into: "Petra Novak", notesDir: e.notes)
        XCTAssertThrowsError(try PeopleMerge.merge("Petra N", into: "Oskar Lind", notesDir: e.notes)) { XCTAssertEqual($0 as? PeopleMerge.Failure, .noPage("Petra N")) }
        // The owner made a new page for that name meanwhile: the undo does not overwrite it.
        try write(e, "Petra N.md", "---\ntype: person\nname: Petra N\n---\nNEW\n")
        XCTAssertThrowsError(try PeopleMerge.separate("Petra N", notesDir: e.notes)) { XCTAssertEqual($0 as? PeopleMerge.Failure, .pageExists("Petra N")) }
        XCTAssertEqual(try read(e, "Petra N.md"), "---\ntype: person\nname: Petra N\n---\nNEW\n")
        XCTAssertTrue(exists(e, "_merged-Petra N.md"))
    }

    func testAChainOfMergesComesApartOneByOne() throws {
        let e = try two()
        try PeopleMerge.merge("Petra N", into: "Petra Novak", notesDir: e.notes)
        try PeopleMerge.merge("Petra Novak", into: "Oskar Lind", notesDir: e.notes)
        try update(e)
        XCTAssertTrue(try read(e, "Oskar Lind.md").contains("3 meetings"))
        XCTAssertEqual(Set(PeopleMerge.setAside(notesDir: e.notes).map { "\($0.name)>\($0.into ?? "-")" }), ["Petra N>Petra Novak", "Petra Novak>Oskar Lind"])
        // Last merged, first undone: Petra Novak's set-aside page still carries Petra N's spelling.
        XCTAssertThrowsError(try PeopleMerge.separate("Petra N", notesDir: e.notes)) {
            XCTAssertEqual($0 as? PeopleMerge.Failure, .undoFirst(name: "Petra Novak", then: "Petra N"))
        }
        XCTAssertTrue(exists(e, "_merged-Petra N.md") && !exists(e, "Petra N.md"), "the refused undo changed nothing")
        try PeopleMerge.separate("Petra Novak", notesDir: e.notes)
        try update(e)
        XCTAssertTrue(try read(e, "Oskar Lind.md").contains("1 meeting"))
        XCTAssertTrue(try read(e, "Petra Novak.md").contains("2 meetings"), "her own earlier merge still stands")
        XCTAssertEqual(PeopleMerge.setAside(notesDir: e.notes).map { "\($0.name)>\($0.into ?? "-")" }, ["Petra N>Petra Novak"])
        try PeopleMerge.separate("Petra N", notesDir: e.notes)
        try update(e)
        XCTAssertTrue(try read(e, "Petra Novak.md").contains("1 meeting") && read(e, "Petra N.md").contains("1 meeting"))
        XCTAssertEqual(PeopleMerge.setAside(notesDir: e.notes).count, 0)
    }

    func testBothSpokeInOneMeetingIsReported() throws {
        let e = try env([(b1, ["SPEAKER_01": "Petra Novak", "SPEAKER_02": "Petra N"], nil), (b2, ["SPEAKER_00": "Petra N"], "Petra Novak")])
        let people = PeoplePages.collect(notesDir: e.notes, workDir: e.work, ownerName: "Dana Owner", timeZone: zone)
        XCTAssertEqual(PeopleMerge.bothSpoke("petra n", "Petra Novak", people: people).count, 1)
        XCTAssertEqual(PeopleMerge.bothSpoke("Petra N", "Nobody", people: people), [])
    }

    func testAPageWithoutTheMeetingsBlockOrFrontmatterAliases() throws {
        let e = try two()
        try write(e, "Petra Novak.md", "---\ntype: person\nname: Petra Novak\n---\nOnly mine.\n")
        try write(e, "Petra N.md", "---\ntype: person\nname: Petra N\nrole: buyer\n---\n")
        try PeopleMerge.merge("Petra N", into: "Petra Novak", notesDir: e.notes)
        let page = try read(e, "Petra Novak.md")
        XCTAssertTrue(page.hasPrefix("---\ntype: person\nname: Petra Novak\naliases: [Petra N]\n---\nOnly mine.\n"))
        XCTAssertTrue(page.contains("## From the page of Petra N (merged)\nRole: buyer\n"))
        try update(e)
        let updated = try read(e, "Petra Novak.md")
        XCTAssertTrue(updated.contains("Only mine.") && updated.contains("Role: buyer") && updated.contains("2 meetings"))
    }

    // MARK: Review of 2026-11-23

    func testUndoKeepsAnAliasTheKeptPageAlreadyHad() throws {
        let e = try two()
        try write(e, "Petra Novak.md", try read(e, "Petra Novak.md").replacingOccurrences(of: "aliases: []", with: "aliases: [Petra]"))
        try write(e, "Petra N.md", try read(e, "Petra N.md").replacingOccurrences(of: "aliases: []", with: "aliases: [Petra, PN]"))
        let before = try read(e, "Petra Novak.md")
        XCTAssertEqual(try PeopleMerge.merge("Petra N", into: "Petra Novak", notesDir: e.notes).aliases, ["Petra N", "PN"])
        XCTAssertTrue(exists(e, "_merged-Petra N.json"))
        XCTAssertEqual(try PeopleMerge.separate("Petra N", notesDir: e.notes).aliases, ["Petra N", "PN"])
        XCTAssertEqual(try read(e, "Petra Novak.md"), before, "\"Petra\" was hers before the merge")
        XCTAssertFalse(exists(e, "_merged-Petra N.json"))
    }

    func testANameAnotherPageAlreadyClaimsIsNotMerged() throws {
        let e = try two()
        try write(e, "Oskar Lind.md", try read(e, "Oskar Lind.md").replacingOccurrences(of: "aliases: []", with: "aliases: [Petra N]"))
        XCTAssertThrowsError(try PeopleMerge.merge("Petra N", into: "Petra Novak", notesDir: e.notes)) {
            XCTAssertEqual($0 as? PeopleMerge.Failure, .claimed(name: "Petra N", by: "Oskar Lind"))
        }
        XCTAssertTrue(exists(e, "Petra N.md"))
        XCTAssertFalse(exists(e, "_merged-Petra N.md"))
    }

    func testUndoIsRefusedWhileAnotherPageListsTheName() throws {
        let e = try two()
        try PeopleMerge.merge("Petra N", into: "Petra Novak", notesDir: e.notes)
        // Afterwards the owner writes the same spelling on another page: it would take the meetings of the
        // page that comes back.
        try write(e, "Oskar Lind.md", try read(e, "Oskar Lind.md").replacingOccurrences(of: "aliases: []", with: "aliases: [Petra N]"))
        XCTAssertEqual(PeopleMerge.setAside(notesDir: e.notes).first?.into, "Petra Novak")
        let kept = try read(e, "Petra Novak.md")
        XCTAssertThrowsError(try PeopleMerge.separate("Petra N", notesDir: e.notes)) {
            XCTAssertEqual($0 as? PeopleMerge.Failure, .claimed(name: "Petra N", by: "Oskar Lind"))
        }
        XCTAssertEqual(try read(e, "Petra Novak.md"), kept)
        XCTAssertTrue(exists(e, "_merged-Petra N.md") && exists(e, "_merged-Petra N.json") && !exists(e, "Petra N.md"))
        // Once the owner takes it off that page the undo goes through.
        try write(e, "Oskar Lind.md", try read(e, "Oskar Lind.md").replacingOccurrences(of: "aliases: [Petra N]", with: "aliases: []"))
        XCTAssertEqual(try PeopleMerge.separate("Petra N", notesDir: e.notes).kept, "Petra Novak")
        XCTAssertTrue(try read(e, "Petra Novak.md").contains("aliases: []"))
    }

    func testWithoutItsRecordTheUndoFindsThePageByTheCopiedText() throws {
        let e = try two()
        try write(e, "Petra N.md", try read(e, "Petra N.md").replacingOccurrences(of: "# Petra N\n", with: "# Petra N\n\nHer line.\n"))
        try PeopleMerge.merge("Petra N", into: "Petra Novak", notesDir: e.notes)
        try FileManager.default.removeItem(at: e.people.appendingPathComponent("_merged-Petra N.json"))
        try write(e, "Oskar Lind.md", try read(e, "Oskar Lind.md").replacingOccurrences(of: "# Oskar Lind\n", with: "# Oskar Lind\n\nKnows Petra N.\n"))
        let out = try PeopleMerge.separate("Petra N", notesDir: e.notes)
        XCTAssertEqual(out.kept, "Petra Novak")
        XCTAssertTrue(out.notes)
        XCTAssertFalse(try read(e, "Petra Novak.md").contains("Her line."))
    }

    func testTwoSetAsidePagesOfOneNameComeBackUnderTheirOwnFileName() throws {
        let e = try two()
        try PeopleMerge.merge("Petra N", into: "Petra Novak", notesDir: e.notes)
        // A new page of the same name appears and is merged somewhere else.
        try write(e, "Petra N.md", "---\ntype: person\nname: Petra N\naliases: []\n---\nSECOND\n")
        try write(e, "Petra Novak.md", try read(e, "Petra Novak.md").replacingOccurrences(of: "aliases: [Petra N]", with: "aliases: []"))
        try PeopleMerge.merge("Petra N", into: "Oskar Lind", notesDir: e.notes)
        let aside = PeopleMerge.setAside(notesDir: e.notes)
        XCTAssertEqual(aside.map { "\($0.file.lastPathComponent)>\($0.into ?? "-")" }, ["_merged-Petra N 2.md>Oskar Lind", "_merged-Petra N.md>Petra Novak"])
        let out = try PeopleMerge.separate(aside[0], notesDir: e.notes)
        XCTAssertEqual(out.kept, "Oskar Lind")
        XCTAssertTrue(try read(e, "Petra N.md").contains("SECOND"), "back under its own file name, not \"Petra N 2.md\"")
        XCTAssertFalse(exists(e, "Petra N 2.md"))
    }

    func testAFinderCopyOfTheKeptPageIsNotThePage() throws {
        let e = try two()
        try write(e, "Petra Novak copy.md", try read(e, "Petra Novak.md") + "COPY\n")
        try PeopleMerge.merge("Petra N", into: "Petra Novak", notesDir: e.notes)
        XCTAssertTrue(try read(e, "Petra Novak.md").contains("aliases: [Petra N]"))
        XCTAssertFalse(try read(e, "Petra Novak copy.md").contains("aliases: [Petra N]"))
        XCTAssertEqual(PeoplePages.pageURL(for: "petra novak", notesDir: e.notes)?.lastPathComponent, "Petra Novak.md")
    }

    // MARK: Review of 2026-11-23, second round

    /// A second file that says it is the other person would become that person's page the moment the first is
    /// set aside, take the meetings back and block the undo.
    func testASecondFileOfTheOtherPersonRefusesTheMerge() throws {
        let e = try two()
        try write(e, "Petra N copy.md", try read(e, "Petra N.md") + "COPY\n")
        let kept = try read(e, "Petra Novak.md")
        XCTAssertThrowsError(try PeopleMerge.merge("Petra N", into: "Petra Novak", notesDir: e.notes)) {
            XCTAssertEqual($0 as? PeopleMerge.Failure, .twoFiles(name: "Petra N", file: "Petra N copy.md"))
        }
        XCTAssertEqual(try read(e, "Petra Novak.md"), kept)
        XCTAssertTrue(exists(e, "Petra N.md") && !exists(e, "_merged-Petra N.md") && !exists(e, "_merged-Petra N.json"))
        try FileManager.default.removeItem(at: e.people.appendingPathComponent("Petra N copy.md"))
        try PeopleMerge.merge("Petra N", into: "Petra Novak", notesDir: e.notes)
        try update(e)
        XCTAssertTrue(try read(e, "Petra Novak.md").contains("2 meetings"))
    }

    func testAMergeOrAnUndoThatFailsChangesNothing() throws {
        let e = try two()
        let fm = FileManager.default
        let keptURL = e.people.appendingPathComponent("Petra Novak.md")
        let kept = try read(e, "Petra Novak.md"), other = try read(e, "Petra N.md")
        // The kept page cannot be replaced: the other page goes back to where it was.
        try fm.setAttributes([.immutable: true], ofItemAtPath: keptURL.path)
        defer { try? fm.setAttributes([.immutable: false], ofItemAtPath: keptURL.path) }
        XCTAssertThrowsError(try PeopleMerge.merge("Petra N", into: "Petra Novak", notesDir: e.notes))
        XCTAssertEqual(try read(e, "Petra N.md"), other)
        XCTAssertEqual(try read(e, "Petra Novak.md"), kept)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: e.people.path).filter { $0.hasPrefix("_merged-") }, [])
        // The other page cannot be moved: the kept page is not touched.
        try fm.setAttributes([.immutable: false], ofItemAtPath: keptURL.path)
        try fm.setAttributes([.immutable: true], ofItemAtPath: e.people.appendingPathComponent("Petra N.md").path)
        XCTAssertThrowsError(try PeopleMerge.merge("Petra N", into: "Petra Novak", notesDir: e.notes))
        try fm.setAttributes([.immutable: false], ofItemAtPath: e.people.appendingPathComponent("Petra N.md").path)
        XCTAssertEqual(try read(e, "Petra Novak.md"), kept)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: e.people.path).filter { $0.hasPrefix("_merged-") }, [])
        // The same for the undo.
        try PeopleMerge.merge("Petra N", into: "Petra Novak", notesDir: e.notes)
        let merged = try read(e, "Petra Novak.md")
        try fm.setAttributes([.immutable: true], ofItemAtPath: keptURL.path)
        XCTAssertThrowsError(try PeopleMerge.separate("Petra N", notesDir: e.notes))
        try fm.setAttributes([.immutable: false], ofItemAtPath: keptURL.path)
        XCTAssertEqual(try read(e, "Petra Novak.md"), merged)
        XCTAssertTrue(exists(e, "_merged-Petra N.md") && exists(e, "_merged-Petra N.json") && !exists(e, "Petra N.md"))
        XCTAssertEqual(try PeopleMerge.separate("Petra N", notesDir: e.notes).aliases, ["Petra N"])
        XCTAssertEqual(try read(e, "Petra Novak.md"), kept)
    }

    func testAnAliasListWithCommentsAndBlankLinesIsLeftAsWritten() throws {
        let e = try two()
        let list = "aliases:\n  - P. Novak\n  # how she signs\n\n  - PN"
        try write(e, "Petra Novak.md", try read(e, "Petra Novak.md").replacingOccurrences(of: "aliases: []", with: list))
        let before = try read(e, "Petra Novak.md")
        try PeopleMerge.merge("Petra N", into: "Petra Novak", notesDir: e.notes)
        let merged = try read(e, "Petra Novak.md")
        XCTAssertTrue(merged.contains(list + "\n  - Petra N\nrole:"), merged)
        XCTAssertEqual(PeoplePages.known(notesDir: e.notes).first { $0.name == "Petra Novak" }?.aliases, ["P. Novak", "PN", "Petra N"])
        try PeopleMerge.separate("Petra N", notesDir: e.notes)
        XCTAssertEqual(try read(e, "Petra Novak.md"), before)
    }

    func testACommentAfterTheAliasesIsNotASpellingAndStays() throws {
        XCTAssertEqual(PeoplePages.aliases(inFrontmatter: "[Petra, \"P #1\"] # old"), ["Petra", "P #1"])
        XCTAssertEqual(PeoplePages.aliases(inFrontmatter: "[Petra #1]"), ["Petra #1"])
        let e = try two()
        try write(e, "Petra Novak.md", try read(e, "Petra Novak.md").replacingOccurrences(of: "aliases: []", with: "aliases: [Petra]  # old"))
        let before = try read(e, "Petra Novak.md")
        try PeopleMerge.merge("Petra N", into: "Petra Novak", notesDir: e.notes)
        XCTAssertTrue(try read(e, "Petra Novak.md").contains("aliases: [Petra, Petra N] # old\n"))
        try PeopleMerge.separate("Petra N", notesDir: e.notes)
        XCTAssertEqual(try read(e, "Petra Novak.md"), before.replacingOccurrences(of: "]  # old", with: "] # old"))
    }

    func testAPageThatHadNoAliasesLineHasNoneAfterTheUndo() throws {
        let e = try two()
        try write(e, "Petra Novak.md", try read(e, "Petra Novak.md").replacingOccurrences(of: "aliases: []\n", with: ""))
        let before = try read(e, "Petra Novak.md")
        try PeopleMerge.merge("Petra N", into: "Petra Novak", notesDir: e.notes)
        XCTAssertTrue(try read(e, "Petra Novak.md").contains("aliases: [Petra N]"))
        try PeopleMerge.separate("Petra N", notesDir: e.notes)
        XCTAssertEqual(try read(e, "Petra Novak.md"), before)
    }

    func testWhatTheOwnerWroteIsCopiedWhole() throws {
        let address = "https://www.linkedin.com/in/petra-novak-0123456789abcdef/?originalSubdomain=uk&trk=people-guest_people_search-card"
        let page = "---\ntype: person\nname: Petra N\nlinkedin: \(address)\nnotes: |\n  Met at the fair.\n  Likes short calls.\nprefers: email; no calls\n---\n# Petra N\n"
        let lines = PeopleMerge.carried(from: page, name: "Petra N")
        XCTAssertEqual(lines, ["## From the page of Petra N (merged)",
                               "LinkedIn: \(address) · notes: Met at the fair. Likes short calls. · prefers: email; no calls", ""])
    }

    /// A page without `name:` set aside under a numbered file name is still the person it was merged as.
    func testANamelessPageSetAsideTwiceKeepsItsName() throws {
        let e = try two()
        try write(e, "Petra N.md", "---\ntype: person\n---\nFIRST\n")
        try PeopleMerge.merge("Petra N", into: "Petra Novak", notesDir: e.notes)
        try write(e, "Petra Novak.md", try read(e, "Petra Novak.md").replacingOccurrences(of: "aliases: [Petra N]", with: "aliases: []"))
        try write(e, "Petra N.md", "---\ntype: person\n---\nSECOND\n")
        try PeopleMerge.merge("Petra N", into: "Oskar Lind", notesDir: e.notes)
        XCTAssertTrue(try read(e, "Oskar Lind.md").contains("## From the page of Petra N (merged)\n\nSECOND\n"))
        let aside = PeopleMerge.setAside(notesDir: e.notes)
        XCTAssertEqual(aside.map(\.name), ["Petra N", "Petra N"])
        let out = try PeopleMerge.separate(aside[0], notesDir: e.notes)
        XCTAssertEqual(out, .init(kept: "Oskar Lind", other: "Petra N", aliases: ["Petra N"], notes: true))
        XCTAssertFalse(try read(e, "Oskar Lind.md").contains("SECOND"))
        XCTAssertEqual(try read(e, "Petra N.md"), "---\ntype: person\n---\nSECOND\n")
    }

    /// A record left behind by a set-aside page the owner deleted says nothing about a later merge of that name.
    func testALeftoverRecordDoesNotSendTheUndoToAnotherPage() throws {
        let e = try two()
        try write(e, "Petra N.md", try read(e, "Petra N.md").replacingOccurrences(of: "# Petra N\n", with: "# Petra N\n\nHer line.\n"))
        try PeopleMerge.merge("Petra N", into: "Petra Novak", notesDir: e.notes)
        try FileManager.default.removeItem(at: e.people.appendingPathComponent("_merged-Petra N.md"))
        try write(e, "Petra Novak.md", try read(e, "Petra Novak.md").replacingOccurrences(of: "aliases: [Petra N]", with: "aliases: []"))
        try write(e, "Oskar Lind.md", try read(e, "Oskar Lind.md").replacingOccurrences(of: "aliases: []", with: "aliases: [Petra N]"))
        try write(e, "Petra N.md", "---\ntype: person\nname: Petra N\n---\nAnother line.\n")
        // Oskar's page lists the name already, so this merge adds no spelling: the record is still written anew.
        try write(e, "Oskar Lind.md", try read(e, "Oskar Lind.md").replacingOccurrences(of: "aliases: [Petra N]", with: "aliases: [petra n]"))
        XCTAssertThrowsError(try PeopleMerge.merge("Petra N", into: "Petra Novak", notesDir: e.notes), "Oskar's page claims the name")
        let out = try PeopleMerge.merge("Petra N", into: "Oskar Lind", notesDir: e.notes)
        XCTAssertEqual(out.aliases, [])
        let novak = try read(e, "Petra Novak.md")
        XCTAssertEqual(try PeopleMerge.separate("Petra N", notesDir: e.notes).kept, "Oskar Lind")
        XCTAssertEqual(try read(e, "Petra Novak.md"), novak, "the first merge's page is not touched")
        XCTAssertFalse(try read(e, "Oskar Lind.md").contains("Another line."))
        XCTAssertTrue(try read(e, "Oskar Lind.md").contains("aliases: [petra n]"), "a spelling the page already had stays")
    }

    func testOtherFrontmatterKeysTheOwnerKeepsAreCopiedToo() throws {
        let e = try two()
        try write(e, "Petra N.md", try read(e, "Petra N.md").replacingOccurrences(of: "linkedin: \n", with: "linkedin: \nemail: petra@example.com\ntags: [buyer]\n"))
        try PeopleMerge.merge("Petra N", into: "Petra Novak", notesDir: e.notes)
        XCTAssertTrue(try read(e, "Petra Novak.md").contains("## From the page of Petra N (merged)\nemail: petra@example.com · tags: [buyer]\n"))
    }
    // MARK: third review

    func testNamesThatDifferOnlyBySharpSAreTwoPeopleForAMerge() throws {
        let e = try env([(b1, ["SPEAKER_01": "Jan Strauß"], nil), (b2, ["SPEAKER_00": "Jan Strauss"], nil),
                         (b3, ["SPEAKER_00": "Oskar Lind"], nil)])
        try update(e)
        XCTAssertEqual(PeoplePages.known(notesDir: e.notes).map(\.name).sorted(), ["Jan Strauss", "Jan Strauß", "Oskar Lind"])
        let out = try PeopleMerge.merge("Jan Strauss", into: "Oskar Lind", notesDir: e.notes)
        XCTAssertEqual(out.other, "Jan Strauss")
        XCTAssertEqual(PeoplePages.known(notesDir: e.notes).map(\.name).sorted(), ["Jan Strauß", "Oskar Lind"], "the ß page is untouched")
        // And the two can be merged with each other.
        _ = try PeopleMerge.separate("Jan Strauss", notesDir: e.notes)
        let both = try PeopleMerge.merge("Jan Strauss", into: "Jan Strauß", notesDir: e.notes)
        XCTAssertEqual(both.kept, "Jan Strauß")
        try update(e)
        XCTAssertEqual(PeoplePages.known(notesDir: e.notes).map(\.name).sorted(), ["Jan Strauß", "Oskar Lind"])
    }

    func testCommentsAndBlockTextInTheFrontmatterAreNotAliases() throws {
        let page = "---\nname: Petra Novak\nnotes: |\n  aliases: [Wrong]\n  role: none\naliases:\n  - Pet  # short\n  # older spellings: below\n  -\tPetra N\n  - \"P #1\"\nrole: buyer\n---\n\nText.\n"
        let fm = PeoplePages.frontmatter(of: page)
        XCTAssertEqual(PeoplePages.aliases(inFrontmatter: fm["aliases"] ?? ""), ["Pet", "Petra N", "P #1"])
        XCTAssertEqual(fm["role"], "buyer")
        XCTAssertEqual(PeoplePages.aliases(inFrontmatter: "[Pet]  # see [[Pet]]"), ["Pet"])
        XCTAssertEqual(PeoplePages.aliases(inFrontmatter: "[\"a]b\", c] # x"), ["a]b", "c"])
        XCTAssertEqual(PeoplePages.aliases(inFrontmatter: "Pet # short"), ["Pet"])
        // Setting them again keeps the comment lines and the block text.
        let again = PeopleMerge.withAliases(page, ["Pet", "Petra N", "P #1", "Nova"])
        XCTAssertTrue(again.contains("  # older spellings: below\n"), again)
        XCTAssertTrue(again.contains("notes: |\n  aliases: [Wrong]\n"), again)
        XCTAssertEqual(PeoplePages.aliases(inFrontmatter: PeoplePages.frontmatter(of: again)["aliases"] ?? ""), ["Pet", "Petra N", "P #1", "Nova"])
        let flow = PeopleMerge.withAliases("---\nname: P\naliases: [Pet]  # see [[Pet]]\n---\n", ["Pet", "Nova"])
        XCTAssertTrue(flow.contains("# see [[Pet]]"), flow)
        XCTAssertEqual(PeoplePages.aliases(inFrontmatter: PeoplePages.frontmatter(of: flow)["aliases"] ?? ""), ["Pet", "Nova"])
    }

    func testUndoSaysWhenTheCopiedTextWasEditedAndStaysOnTheKeptPage() throws {
        let e = try two()
        try write(e, "Petra N.md", try read(e, "Petra N.md") + "\nMet at the fair.\n")
        try PeopleMerge.merge("Petra N", into: "Petra Novak", notesDir: e.notes)
        XCTAssertFalse(try { let c = try self.two(); _ = try PeopleMerge.merge("Petra N", into: "Petra Novak", notesDir: c.notes)
            return try PeopleMerge.separate("Petra N", notesDir: c.notes).textLeft }())
        try write(e, "Petra Novak.md", try read(e, "Petra Novak.md").replacingOccurrences(of: "Met at the fair.", with: "Met at the fair in Vic."))
        let out = try PeopleMerge.separate("Petra N", notesDir: e.notes)
        XCTAssertTrue(out.textLeft)
        XCTAssertTrue(try read(e, "Petra Novak.md").contains("Met at the fair in Vic."))
    }

    func testUndoFindsTheKeptPageAfterTheOwnerRenamedIt() throws {
        let e = try two()
        try PeopleMerge.merge("Petra N", into: "Petra Novak", notesDir: e.notes)
        let kept = try read(e, "Petra Novak.md").replacingOccurrences(of: "name: Petra Novak", with: "name: Petra Novakova")
        try FileManager.default.removeItem(at: e.people.appendingPathComponent("Petra Novak.md"))
        try write(e, "Petra Novakova.md", kept)
        let out = try PeopleMerge.separate("Petra N", notesDir: e.notes)
        XCTAssertEqual(out.kept, "Petra Novakova")
        XCTAssertFalse(try read(e, "Petra Novakova.md").contains("Petra N]"))
        XCTAssertTrue(exists(e, "Petra N.md"))
    }

    func testANamedSpeakerWithoutTimedWordsStillSpoke() throws {
        let e = try env([(b1, ["SPEAKER_00": "Petra Novak", "SPEAKER_01": "Oskar Lind", "SPEAKER_02": "Gone Person"], nil)])
        try TranscriptSegments(segments: [.init(start: 0, end: 5, text: "hello", speaker: "Petra Novak")]).save(workDir: e.work, base: b1)
        try "[Petra Novak]\nhello\n\n[Oskar Lind]\nyes\n".write(to: Pipeline.cachedTranscriptURL(workDir: e.work, base: b1), atomically: true, encoding: .utf8)
        try update(e)
        XCTAssertEqual(PeoplePages.known(notesDir: e.notes).map(\.name).sorted(), ["Oskar Lind", "Petra Novak"])
    }

    // MARK: a role the merge brought in leaves with the undo

    /// Petra Novak's page has empty `role:` / `organisation:`; Oskar Lind was listed as "(Acme) - buyer".
    private func roleCase() throws -> Env {
        let e = try env([(b1, ["SPEAKER_01": "Petra Novak"], nil), (b3, [:], "Oskar Lind (Acme) - buyer")])
        try update(e)
        XCTAssertTrue(try read(e, "Petra Novak.md").contains("role: \norganisation: \n"))
        XCTAssertTrue(try read(e, "Oskar Lind.md").contains("role: buyer\norganisation: Acme\n"))
        return e
    }

    func testUndoAfterAnUpdateTakesBackTheRoleTheMergeBroughtIn() throws {
        let e = try roleCase()
        let kept = try read(e, "Petra Novak.md"), index = try read(e, "_People.md"), orgs = try read(e, "_Organisations.md")
        try PeopleMerge.merge("Oskar Lind", into: "Petra Novak", notesDir: e.notes)
        try update(e)
        XCTAssertTrue(try read(e, "Petra Novak.md").contains("role: buyer\norganisation: Acme\n"), "the update fills the empty fields")
        try PeopleMerge.separate("Oskar Lind", notesDir: e.notes)
        try update(e)
        XCTAssertEqual(try read(e, "Petra Novak.md"), kept)
        XCTAssertEqual(try read(e, "_People.md"), index)
        XCTAssertEqual(try read(e, "_Organisations.md"), orgs)
    }

    func testARoleTheOwnerTypedWhileMergedStaysAfterTheUndo() throws {
        let e = try roleCase()
        try PeopleMerge.merge("Oskar Lind", into: "Petra Novak", notesDir: e.notes)
        try update(e)
        try write(e, "Petra Novak.md", try read(e, "Petra Novak.md").replacingOccurrences(of: "role: buyer\n", with: "role: director\n"))
        try PeopleMerge.separate("Oskar Lind", notesDir: e.notes)
        try update(e)
        let page = try read(e, "Petra Novak.md")
        XCTAssertTrue(page.contains("role: director\n"), page)
        XCTAssertTrue(page.contains("organisation: \n"), "the organisation the merge brought in goes: \(page)")
    }

    func testARoleTheKeptPageHadBeforeTheMergeIsUntouched() throws {
        let e = try roleCase()
        // The same words as the other page's, in other capitals: still Petra's own.
        try write(e, "Petra Novak.md", try read(e, "Petra Novak.md").replacingOccurrences(of: "role: \norganisation: \n", with: "role: Buyer\norganisation: ACME\n"))
        try update(e)
        let kept = try read(e, "Petra Novak.md")
        try PeopleMerge.merge("Oskar Lind", into: "Petra Novak", notesDir: e.notes)
        try update(e)
        try PeopleMerge.separate("Oskar Lind", notesDir: e.notes)
        try update(e)
        XCTAssertEqual(try read(e, "Petra Novak.md"), kept)
    }

    func testARecordWrittenBeforeTheFieldsWereNotedUndoesAsBefore() throws {
        let e = try roleCase()
        try PeopleMerge.merge("Oskar Lind", into: "Petra Novak", notesDir: e.notes)
        let recordURL = e.people.appendingPathComponent("_merged-Oskar Lind.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: recordURL)) as? [String: Any])
        json.removeValue(forKey: "emptyFields")
        try JSONSerialization.data(withJSONObject: json).write(to: recordURL)
        try update(e)
        let out = try PeopleMerge.separate("Oskar Lind", notesDir: e.notes)
        XCTAssertEqual(out.kept, "Petra Novak")
        XCTAssertEqual(out.aliases, ["Oskar Lind"])
        XCTAssertTrue(exists(e, "Oskar Lind.md"))
        XCTAssertFalse(exists(e, "_merged-Oskar Lind.json"))
        let page = try read(e, "Petra Novak.md")
        XCTAssertTrue(page.contains("aliases: []\n"), page)
        XCTAssertTrue(page.contains("role: buyer\norganisation: Acme\n"), "without the note, the fields are left as they are")
    }

    func testACompanyWithAndInItsNameIsNotASecondPerson() {
        XCTAssertEqual(PeoplePages.joined("Anna from Marks and Spencer for the audit").count, 1)
        XCTAssertEqual(PeoplePages.joined("Pere from Acme (Head of Sales and Marketing for EMEA)").count, 1)
        XCTAssertEqual(PeoplePages.joined("Anna from Acme and Pere from Initech").count, 2)
        XCTAssertEqual(PeoplePages.joined("Anna at Acme and Pere at Initech").count, 2)
    }
    /// The role came from what the other person SAID in a meeting, and their own page had another role typed
    /// by the owner: the set-aside page does not hold the value, the record of the update does.
    func testUndoTakesBackARoleTheUpdatePutInEvenWhenTheOtherPageSaysSomethingElse() throws {
        let e = try env([(b1, ["SPEAKER_01": "Petra Novak"], nil), (b2, [:], "Oskar Lind (Acme) - buyer")])
        try update(e)
        try write(e, "Oskar Lind.md", try read(e, "Oskar Lind.md").replacingOccurrences(of: "role: buyer", with: "role: head of buying"))
        try update(e)
        let before = try ["Petra Novak.md", "_People.md", "_Organisations.md"].map { try read(e, $0) }
        XCTAssertTrue(before[0].contains("role: \n"))
        try PeopleMerge.merge("Oskar Lind", into: "Petra Novak", notesDir: e.notes)
        try update(e)
        XCTAssertTrue(try read(e, "Petra Novak.md").contains("role: buyer"))
        try PeopleMerge.separate("Oskar Lind", notesDir: e.notes)
        try update(e)
        XCTAssertEqual(try ["Petra Novak.md", "_People.md", "_Organisations.md"].map { try read(e, $0) }, before)
    }
    /// The kept page's person has no meeting left (its block is history): after merge + undo it does not keep
    /// the other person's meetings.
    func testUndoGivesAPageWithoutMeetingsItsOldBlockBack() throws {
        let e = try two()
        // Petra Novak's only meeting loses its name: her page stays, with the block as it was.
        try FileManager.default.removeItem(at: SpeakerNames.url(workDir: e.work, base: b1))
        try update(e)
        let before = try ["Petra Novak.md", "Petra N.md", "_People.md"].map { try read(e, $0) }
        XCTAssertTrue(before[0].contains("1 meeting"))
        try PeopleMerge.merge("Petra N", into: "Petra Novak", notesDir: e.notes)
        try update(e)
        XCTAssertTrue(try read(e, "Petra Novak.md").contains("2026-11-19"))
        try PeopleMerge.separate("Petra N", notesDir: e.notes)
        try update(e)
        XCTAssertEqual(try ["Petra Novak.md", "Petra N.md", "_People.md"].map { try read(e, $0) }, before)
    }
}
