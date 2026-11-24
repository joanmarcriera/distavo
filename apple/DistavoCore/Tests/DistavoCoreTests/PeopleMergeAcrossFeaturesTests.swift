import XCTest
@testable import DistavoCore

/// What the other people features do once two pages were merged, and after the merge is undone: the brief, Ask,
/// the participants line, the pop-up of known people. Synthetic names only.
final class PeopleMergeAcrossFeaturesTests: XCTestCase {
    private let zone = TimeZone(identifier: "Europe/London")!
    private typealias Env = (notes: URL, work: URL, people: URL)
    private let b1 = "Meeting_2026-11-18_09.00.00", b2 = "Meeting_2026-11-19_14.30.00", b3 = "Meeting_2026-11-20_10.00.00"

    private func env() throws -> Env {
        let root = TestTemp.root.appendingPathComponent("distavo-mergeacross-\(UUID().uuidString)")
        let notes = root.appendingPathComponent("notes"), work = root.appendingPathComponent("work")
        let people = PeoplePages.folder(notesDir: notes)
        for d in [work, people] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        let meetings: [(String, [String: String], String)] = [
            (b1, ["SPEAKER_01": "Petra Novak"], "- [ ] Send the offer - owner: Petra Novak\n"),
            (b2, ["SPEAKER_00": "Petra N"], "- [ ] Book the room - owner: Petra N\n- [ ] Call the bank - owner: Oskar\n"),
            (b3, ["SPEAKER_00": "Oskar Lind"], "")]
        for (base, names, tasks) in meetings {
            try "# Call\n\nText.\n\n## Action items\n\(tasks)".write(to: notes.appendingPathComponent("\(base).md"), atomically: true, encoding: .utf8)
            try SpeakerNames(names: names).encoded().write(to: SpeakerNames.url(workDir: work, base: base))
        }
        let e: Env = (notes, work, people)
        try update(e)
        return e
    }
    @discardableResult
    private func update(_ e: Env) throws -> PeoplePages.Summary {
        try PeoplePages.update(notesDir: e.notes, workDir: e.work, ownerName: "Dana Owner", timeZone: zone)
    }
    private func read(_ e: Env, _ file: String) throws -> String { try String(contentsOf: e.people.appendingPathComponent(file), encoding: .utf8) }
    private func brief(_ e: Env, _ names: [String]) -> [MeetingBrief.Entry] {
        MeetingBrief.entries(for: names, notesDir: e.notes, workDir: e.work, ownerName: "Dana Owner", timeZone: zone)
    }
    private func asked(_ e: Env, _ q: String) -> Set<String> {
        AskPeople.bases(for: q, notesDir: e.notes, workDir: e.work, ownerName: "Dana Owner", timeZone: zone)
    }

    func testTheBriefAndAskSeeOnePersonRightAfterTheMergeEvenBeforeThePagesAreUpdated() throws {
        let e = try env()
        XCTAssertEqual(brief(e, ["Petra N"]).first?.person?.meetings.count, 1)
        _ = try PeopleMerge.merge("Petra N", into: "Petra Novak", notesDir: e.notes)
        // No update in between: the merge alone is enough for the readers.
        for askedAs in ["Petra N", "Petra Novak", "petra novak", "Petra"] {
            let entries = brief(e, [askedAs])
            XCTAssertEqual(entries.count, 1, askedAs)
            XCTAssertEqual(entries.first?.person?.name, "Petra Novak", askedAs)
            XCTAssertEqual(entries.first?.person?.meetings.map(\.base), [b2, b1], askedAs)
            XCTAssertEqual(entries.first?.theirs.map(\.title).sorted(), ["Book the room", "Send the offer"], askedAs)
            XCTAssertEqual(entries.first?.others.map(\.title), ["Call the bank"], askedAs)
        }
        XCTAssertEqual(brief(e, ["Petra N", "Petra Novak"]).count, 1, "two spellings of one person are one entry")
        XCTAssertEqual(asked(e, "what did Petra N promise?"), [b1, b2])
        XCTAssertEqual(asked(e, "what did Petra Novak promise?"), [b1, b2])
        XCTAssertEqual(asked(e, "what did Oskar Lind promise?"), [b3])
    }

    func testThePeoplePopUpAndTheParticipantsLineKnowOnlyTheKeptPage() throws {
        let e = try env()
        var page = try read(e, "Petra Novak.md")
        page = page.replacingOccurrences(of: "role: ", with: "role: buyer").replacingOccurrences(of: "organisation: ", with: "organisation: Acme")
        try page.write(to: e.people.appendingPathComponent("Petra Novak.md"), atomically: true, encoding: .utf8)
        _ = try PeopleMerge.merge("Petra N", into: "Petra Novak", notesDir: e.notes)
        try update(e)
        XCTAssertEqual(PeoplePages.suggestions(notesDir: e.notes).map(\.name).sorted(), ["Oskar Lind", "Petra Novak"])
        let line = PeoplePages.participants("Petra N", alsoPresent: [], notesDir: e.notes)
        XCTAssertEqual(line, "Petra N. " + PeoplePages.knownLead + "Petra Novak: buyer, Acme.")
        XCTAssertEqual(PeoplePages.participants(nil, alsoPresent: ["Petra N", "Petra Novak"], notesDir: e.notes),
                       PeoplePages.knownLead + "Petra Novak: buyer, Acme.")
        // Typed as the old spelling, the person is already there.
        let known = try XCTUnwrap(PeoplePages.known(notesDir: e.notes).first { $0.name == "Petra Novak" })
        XCTAssertEqual(PeoplePages.adding(known, to: "Petra N"), "Petra N")
        // The lists Distavo writes name the person once and never the set-aside page.
        for file in ["_People.md", "_Organisations.md"] {
            let text = try read(e, file)
            XCTAssertFalse(text.contains("_merged-"), file)
            XCTAssertFalse(text.contains("[Petra N]"), file)
        }
    }

    func testANewMeetingUnderTheOldSpellingGoesToTheKeptPageAndBackAfterTheUndo() throws {
        let e = try env()
        _ = try PeopleMerge.merge("Petra N", into: "Petra Novak", notesDir: e.notes)
        try update(e)
        let b4 = "Meeting_2026-11-21_11.00.00"
        try "# Later\n".write(to: e.notes.appendingPathComponent("\(b4).md"), atomically: true, encoding: .utf8)
        try SpeakerNames(names: ["SPEAKER_00": "petra n"]).encoded().write(to: SpeakerNames.url(workDir: e.work, base: b4))
        let s = try update(e)
        XCTAssertEqual(s.created, [])
        XCTAssertTrue(try read(e, "Petra Novak.md").contains("3 meetings"))

        _ = try PeopleMerge.separate("Petra N", notesDir: e.notes)
        let after = try update(e)
        XCTAssertEqual(after.created, [])
        let kept = try read(e, "Petra Novak.md"), back = try read(e, "Petra N.md")
        XCTAssertTrue(kept.contains("1 meeting"), kept)
        XCTAssertFalse(try read(e, "Petra Novak.md").contains("aliases: [Petra N]"))
        XCTAssertTrue(back.contains("2 meetings"), back)
        XCTAssertEqual(brief(e, ["Petra N"]).first?.person?.meetings.map(\.base), [b4, b2])
        XCTAssertEqual(brief(e, ["Petra"]).first?.person, nil, "two Petras again: a bare first name names nobody")
        XCTAssertEqual(asked(e, "what did Petra Novak promise?"), [b1])
        // A second update changes nothing.
        let again = try update(e)
        XCTAssertEqual(again.updated, [])
        XCTAssertEqual(again.created, [])
    }

    func testMergingTwiceAndUndoingTwiceEndsWhereItStarted() throws {
        let e = try env()
        let before = try ["Petra N.md", "Petra Novak.md", "Oskar Lind.md"].map { try read(e, $0) }
        for _ in 0..<2 {
            _ = try PeopleMerge.merge("Petra N", into: "Petra Novak", notesDir: e.notes)
            try update(e)
            _ = try PeopleMerge.separate("Petra N", notesDir: e.notes)
            try update(e)
        }
        XCTAssertEqual(try ["Petra N.md", "Petra Novak.md", "Oskar Lind.md"].map { try read(e, $0) }, before)
        let left = try FileManager.default.contentsOfDirectory(atPath: e.people.path).filter { $0.hasPrefix("_merged-") }
        XCTAssertEqual(left, [], "no set-aside page or record is left behind")
    }

    func testMergingTheOtherWayRoundAfterAnUndo() throws {
        let e = try env()
        _ = try PeopleMerge.merge("Petra N", into: "Petra Novak", notesDir: e.notes)
        try update(e)
        _ = try PeopleMerge.separate("Petra N", notesDir: e.notes)
        try update(e)
        _ = try PeopleMerge.merge("Petra Novak", into: "Petra N", notesDir: e.notes)
        try update(e)
        XCTAssertEqual(PeoplePages.known(notesDir: e.notes).map(\.name), ["Oskar Lind", "Petra N"])
        XCTAssertTrue(try read(e, "Petra N.md").contains("2 meetings"))
        XCTAssertEqual(PeopleMerge.setAside(notesDir: e.notes).map(\.name), ["Petra Novak"])
        XCTAssertEqual(brief(e, ["Petra Novak"]).first?.person?.name, "Petra N")
    }
}
