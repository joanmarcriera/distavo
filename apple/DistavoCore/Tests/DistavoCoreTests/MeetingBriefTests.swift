import XCTest
@testable import DistavoCore

/// `MeetingBrief`: last meetings and open tasks per person, no model. Synthetic names only.
final class MeetingBriefTests: XCTestCase {
    private let zone = TimeZone(identifier: "Europe/London")!
    private let now = Date(timeIntervalSince1970: 1_795_000_000)

    private func fixture() throws -> (notes: URL, work: URL) {
        let root = TestTemp.root.appendingPathComponent("distavo-brief-\(UUID().uuidString)")
        let notes = root.appendingPathComponent("notes"), work = root.appendingPathComponent("work")
        for d in [notes, work] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        func note(_ base: String, _ title: String, _ tasks: String, _ names: [String: String]) throws {
            try "# \(title)\n\n## Action items\n\(tasks)".write(to: notes.appendingPathComponent("\(base).md"), atomically: true, encoding: .utf8)
            try SpeakerNames(names: names).encoded().write(to: SpeakerNames.url(workDir: work, base: base))
        }
        try note("Meeting_2026-11-10_09.00.00", "Kickoff", "- [ ] Send the drawings - owner: Oskar Lind; due: 2026-11-20\n- [x] Book the room - owner: Oskar Lind\n", ["S0": "Oskar Lind"])
        try note("Meeting_2026-11-12_09.00.00", "Pricing", "- [ ] Confirm the price - owner: Oskar\n- [ ] Share the deck - owner: Dana Owner\n", ["S0": "Oskar Lind", "S1": "Petra Novak"])
        try note("Meeting_2026-11-14_09.00.00", "Review", "- [ ] Unowned thing\n", ["S0": "Oskar Lind"])
        try note("Meeting_2026-11-16_09.00.00", "Wrap up", "", ["S0": "Oscar Lind"])
        try note("Meeting_2026-11-17_09.00.00", "Someone else", "- [ ] Not about Oskar - owner: Oskar Lind\n", ["S0": "Jo Marsh"])
        return (notes, work)
    }

    func testNamesFromATypedList() {
        XCTAssertEqual(MeetingBrief.names(in: "Anna (Acme, Inc) - buyer, Pere and Jo; anna\n"), ["Anna", "Pere", "Jo"])
        XCTAssertEqual(MeetingBrief.names(in: "  ,; "), [])
    }

    func testLastMeetingsAndOpenTasksOfTheirMeetingsOnly() throws {
        let (notes, work) = try fixture()
        let people = PeoplePages.folder(notesDir: notes)
        try FileManager.default.createDirectory(at: people, withIntermediateDirectories: true)
        try "---\ntype: person\nname: Oskar Lind\naliases: [Oscar Lind]\nrole: buyer\norganisation: Acme\n---\n"
            .write(to: people.appendingPathComponent("Oskar Lind.md"), atomically: true, encoding: .utf8)
        let e = MeetingBrief.entries(for: ["oskar", "Oscar Lind", "Nobody Known"], notesDir: notes, workDir: work,
                                     ownerName: "Dana Owner", timeZone: zone)
        XCTAssertEqual(e.map(\.asked), ["oskar", "Nobody Known"])   // two spellings, one person
        XCTAssertEqual(e[0].person?.meetings.count, 4)
        XCTAssertEqual(e[0].theirs.map(\.title), ["Confirm the price", "Send the drawings"])   // newest note first; done and other meetings left out
        XCTAssertEqual(Set(e[0].others.map(\.title)), ["Share the deck", "Unowned thing"])
        XCTAssertNil(e[1].person)

        let text = MeetingBrief.markdown(e, now: now, timeZone: zone)
        XCTAssertTrue(text.contains("## Oskar Lind\nbuyer, Acme\n4 meetings · last 2026-11-16\n"), text)
        XCTAssertEqual(text.components(separatedBy: "](../Meeting_").count - 1, 3, "three meetings shown")
        XCTAssertTrue(text.contains("- Send the drawings (owner: Oskar Lind; due: 2026-11-20)"))
        XCTAssertTrue(text.contains("## Nobody Known\nNo meeting with a confirmed"))
        XCTAssertFalse(text.contains("- [ ]"), "a brief never adds tasks to Action Items")
        XCTAssertFalse(text.contains("Not about Oskar"))
    }

    func testWritingTwiceIsStableAndIsNotAPersonOrATaskSource() throws {
        let (notes, work) = try fixture()
        let before = ActionItems.scan(notesDir: notes).flatMap(\.items).count
        let url = try MeetingBrief.write(for: ["Oskar Lind"], notesDir: notes, workDir: work, now: now, timeZone: zone)
        let first = try String(contentsOf: url, encoding: .utf8)
        try MeetingBrief.write(for: ["Oskar Lind"], notesDir: notes, workDir: work, now: now, timeZone: zone)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), first)
        XCTAssertEqual(ActionItems.scan(notesDir: notes).flatMap(\.items).count, before)
        XCTAssertTrue(PeoplePages.known(notesDir: notes).isEmpty)
        let s = try PeoplePages.update(notesDir: notes, workDir: work, timeZone: zone)
        XCTAssertFalse(s.created.contains { $0.contains("Brief") })
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), first, "the people update leaves the brief alone")
    }

    func testNobodyNamed() {
        XCTAssertTrue(MeetingBrief.markdown([], now: now, timeZone: zone).contains("Nobody named"))
    }
    /// The note spells the name as the transcript heard it ("Oscar Lind"); the owner named the speaker Oskar Lind.
    func testATaskUnderTheTranscriptsSpellingOfTheNameIsTheirs() throws {
        let root = TestTemp.root.appendingPathComponent("distavo-brief2-\(UUID().uuidString)")
        let notes = root.appendingPathComponent("notes"), work = root.appendingPathComponent("work")
        for d in [notes, work] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        try "# Call\n\n## Tasks\n- [ ] Send the contract - owner: Oscar Lind\n- [ ] Book the crew - owner: Petra Novak\n- [ ] Ask Ana - owner: Oskar Lund-Berg\n"
            .write(to: notes.appendingPathComponent("Meeting_2026-11-10_09.00.00.md"), atomically: true, encoding: .utf8)
        try SpeakerNames(names: ["S0": "Oskar Lind", "S1": "Petra Novak"]).encoded().write(to: SpeakerNames.url(workDir: work, base: "Meeting_2026-11-10_09.00.00"))
        let e = MeetingBrief.entries(for: ["Oskar Lind"], notesDir: notes, workDir: work, timeZone: TimeZone(identifier: "Europe/London")!)
        XCTAssertEqual(e.first?.theirs.map(\.title), ["Send the contract"])
        XCTAssertEqual(e.first?.others.map(\.title), ["Book the crew", "Ask Ana"])
        XCTAssertTrue(MeetingBrief.nearSpelling("oscar lind", "oskar lind"))
        XCTAssertTrue(MeetingBrief.nearSpelling("petra novak", "petra nowak"))
        for (a, b) in [("anna puig", "anna puig"), ("anna", "anne"), ("ana puig", "eva puig"), ("pere soler", "pere vila"), ("jo marsh", "jo march x")] {
            XCTAssertFalse(MeetingBrief.nearSpelling(a, b), "\(a) / \(b)")
        }
        // In the existing fixture Oscar Lind is a confirmed person of his own: nothing of his goes to Oskar.
        let f = try fixture()
        try "# Wrap up\n\n## Tasks\n- [ ] Oscar's own task - owner: Oscar Lind\n".write(to: f.notes.appendingPathComponent("Meeting_2026-11-16_09.00.00.md"), atomically: true, encoding: .utf8)
        try SpeakerNames(names: ["S0": "Oscar Lind", "S1": "Oskar Lind"]).encoded().write(to: SpeakerNames.url(workDir: f.work, base: "Meeting_2026-11-16_09.00.00"))
        let g = MeetingBrief.entries(for: ["Oskar Lind"], notesDir: f.notes, workDir: f.work, timeZone: TimeZone(identifier: "Europe/London")!)
        XCTAssertFalse(g.first?.theirs.contains { $0.title == "Oscar's own task" } ?? true)
    }
}
