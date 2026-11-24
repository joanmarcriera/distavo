import XCTest
@testable import DistavoCore

/// `DayLog` (D102): one file per day in notes/day-logs/. Synthetic notes only.
final class DayLogTests: XCTestCase {
    private let zone = TimeZone(identifier: "Europe/London")!

    private func day(_ d: Int, _ h: Int = 9, _ m: Int = 0) -> Date {
        var c = DateComponents(); c.year = 2026; c.month = 11; c.day = d; c.hour = h; c.minute = m
        var cal = Calendar(identifier: .gregorian); cal.timeZone = zone
        return cal.date(from: c)!
    }

    /// Notes named like the recorder names them (the date is read from the name).
    private func fixture() throws -> (notes: URL, work: URL) {
        let root = TestTemp.root.appendingPathComponent("distavo-daylog-\(UUID().uuidString)")
        let notes = root.appendingPathComponent("notes"), work = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        func write(_ name: String, _ text: String) throws {
            try text.write(to: notes.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try write("Meeting_2026-11-18_14.30.00.md", """
        # Supplier call

        ## Action items
        - [ ] Oskar asks two suppliers for quotes
        - [x] Petra orders gloves

        SPEAKER_01 said the pipes are late.

        _Summary: Template: Standard notes (auto)._
        """)
        try write("Meeting_2026-11-18_09.00.00.md", """
        # Garden planning call

        > [!warning] Check this note
        > - The recording may have stopped before the call ended.

        ## Tasks
        - [ ] Nadia prints the posters
        """)
        try write("Meeting_2026-11-18_11.15.00.md", "# Volunteer catch-up\n\nNothing to do.\n")
        try write("Meeting_2026-11-19_10.00.00.md", "# Next day\n\n- [ ] Not today\n")
        return (notes, work)
    }

    func testThreeNotesOfOneDayInTimeOrderOtherDayExcluded() throws {
        let (notes, work) = try fixture()
        let text = DayLog.render(day: day(18), notesDir: notes, workDir: work, timeZone: zone)
        let garden = try XCTUnwrap(text.range(of: "Garden planning call"))
        let volunteer = try XCTUnwrap(text.range(of: "Volunteer catch-up"))
        let supplier = try XCTUnwrap(text.range(of: "Supplier call"))
        XCTAssertLessThan(garden.lowerBound, volunteer.lowerBound)
        XCTAssertLessThan(volunteer.lowerBound, supplier.lowerBound)
        XCTAssertFalse(text.contains("Next day"))
        XCTAssertTrue(text.contains("- 09:00 · [Garden planning call]"))
        XCTAssertTrue(text.contains("template: Standard notes"))
    }

    func testOpenActionsOnlyAndNoCheckboxes() throws {
        let (notes, work) = try fixture()
        let text = DayLog.render(day: day(18), notesDir: notes, workDir: work, timeZone: zone)
        XCTAssertTrue(text.contains("Oskar asks two suppliers for quotes"))
        XCTAssertTrue(text.contains("Nadia prints the posters"))
        XCTAssertFalse(text.contains("Petra orders gloves"), "checked items are left out")
        XCTAssertFalse(text.contains("Not today"))
        // Plain bullets: the Action Items window (recursive scan) must not list them twice.
        XCTAssertTrue(ActionItems.parse(text).isEmpty)
    }

    func testUnnamedSpeakersAndWarningsListed() throws {
        let (notes, work) = try fixture()
        let text = DayLog.render(day: day(18), notesDir: notes, workDir: work, timeZone: zone)
        XCTAssertTrue(text.contains("SPEAKER_01"))
        XCTAssertTrue(text.contains("The recording may have stopped before the call ended."))
    }

    func testLinksAreRelativeAndResolve() throws {
        let (notes, work) = try fixture()
        let url = try DayLog.write(day: day(18), notesDir: notes, workDir: work, timeZone: zone)
        let text = try String(contentsOf: url, encoding: .utf8)
        let links = DayLog.linkTargets(in: text)
        XCTAssertFalse(links.isEmpty)
        for link in links {
            XCTAssertTrue(link.hasPrefix("../"), link)
            let decoded = try XCTUnwrap(link.removingPercentEncoding)
            let target = url.deletingLastPathComponent().appendingPathComponent(decoded).standardizedFileURL
            XCTAssertTrue(FileManager.default.fileExists(atPath: target.path), link)
        }
    }

    func testNoNotesWritesAFileSayingSo() throws {
        let (notes, work) = try fixture()
        let url = try DayLog.write(day: day(1), notesDir: notes, workDir: work, timeZone: zone)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains(DayLog.noNotes))
        XCTAssertTrue(text.hasPrefix("---\ntype: day-log\ndate: 2026-11-01\n---\n"))
    }

    func testWritingTwiceGivesIdenticalBytes() throws {
        let (notes, work) = try fixture()
        let a = try Data(contentsOf: DayLog.write(day: day(18), notesDir: notes, workDir: work, timeZone: zone))
        let b = try Data(contentsOf: DayLog.write(day: day(18), notesDir: notes, workDir: work, timeZone: zone))
        XCTAssertEqual(a, b)
    }

    func testFileLandsInDayLogsAndIsNotListedAsANote() throws {
        let (notes, work) = try fixture()
        let url = try DayLog.write(day: day(18), notesDir: notes, workDir: work, timeZone: zone)
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, DayLog.folderName)
        XCTAssertEqual(url.lastPathComponent, "2026-11-18-day.md")
        let listed = NotesLibrary.scan(notesDir: notes, workDir: work, timeZone: zone).map(\.base)
        XCTAssertEqual(listed.count, 4)
        XCTAssertFalse(listed.contains { $0.contains("day") })
    }

    func testFrontmatterTypeAndTitle() throws {
        let (notes, work) = try fixture()
        let text = DayLog.render(day: day(18), notesDir: notes, workDir: work, timeZone: zone)
        XCTAssertTrue(text.hasPrefix("---\ntype: day-log\ndate: 2026-11-18\n---\n# Day log: Wed 18 Nov 2026\n"))
    }

    func testLinksMayAskOnlyForThePastYear() {
        let today = day(23, 15)
        XCTAssertTrue(DayLog.allowedFromLink(isoDate: nil, today: today, timeZone: zone))
        XCTAssertTrue(DayLog.allowedFromLink(isoDate: "2026-11-23", today: today, timeZone: zone))
        XCTAssertTrue(DayLog.allowedFromLink(isoDate: "2025-11-23", today: today, timeZone: zone))
        XCTAssertFalse(DayLog.allowedFromLink(isoDate: "2026-11-24", today: today, timeZone: zone), "no future days")
        XCTAssertFalse(DayLog.allowedFromLink(isoDate: "2020-01-01", today: today, timeZone: zone))
        XCTAssertFalse(DayLog.allowedFromLink(isoDate: "nonsense", today: today, timeZone: zone))
    }

    func testDateParsing() {
        XCTAssertNotNil(DayLog.date(fromISO: "2026-11-18", timeZone: zone))
        for bad in ["2026-13-01", "2026-11-31", "18-11-2026", "2026-11-1", "2026-11-18T00", "", "../x"] {
            XCTAssertNil(DayLog.date(fromISO: bad, timeZone: zone), bad)
        }
    }
}

extension AutomationCommandTests {
    func testDayLogCommand() {
        XCTAssertEqual(AutomationCommand.parse("distavo://daylog?date=2026-11-18"), .dayLog(date: "2026-11-18"))
        XCTAssertEqual(AutomationCommand.parse("distavo://daylog"), .dayLog(date: nil))
        for bad in ["distavo://daylog?date=2026-11-31", "distavo://daylog?date=../../etc", "distavo://daylog?date=18-11-2026",
                    "distavo://daylog/2026-11-18", "distavo://daylog?date=2026-11-18&date=2026-11-19"] {
            XCTAssertNil(AutomationCommand.parse(bad), bad)
        }
        XCTAssertFalse(AutomationCommand.dayLog(date: nil).requiresConfirmation)
    }
}

/// Review round 2 (drive 2026-11-23); an extension so it can use the fixture above.
extension DayLogTests {
    // Review round 2 (drive 2026-11-23).
    func testAnEditedLogIsKeptAsABackupAndALinkNeverRewrites() throws {
        let (notes, work) = try fixture()
        let url = try DayLog.write(day: day(18), notesDir: notes, workDir: work, timeZone: zone)
        try "my own notes about the day\n".write(to: url, atomically: true, encoding: .utf8)
        _ = try DayLog.write(day: day(18), notesDir: notes, workDir: work, timeZone: zone, onlyIfMissing: true)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "my own notes about the day\n", "a link leaves it")
        _ = try DayLog.write(day: day(18), notesDir: notes, workDir: work, timeZone: zone, now: day(18, 22))
        let names = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        let backup = try XCTUnwrap(names.first { NoteVersions.isBackupName($0) })
        XCTAssertEqual(try String(contentsOf: url.deletingLastPathComponent().appendingPathComponent(backup), encoding: .utf8),
                       "my own notes about the day\n")
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).hasPrefix("---\ntype: day-log"))
    }

    func testActionItemsWindowSkipsDayLogs() throws {
        let (notes, work) = try fixture()
        let url = try DayLog.write(day: day(18), notesDir: notes, workDir: work, timeZone: zone)
        try "# Hand edit\n- [ ] a box typed into the day log\n".write(to: url, atomically: true, encoding: .utf8)
        let scanned = ActionItems.scan(notesDir: notes)
        XCTAssertFalse(scanned.contains { $0.path.contains(DayLog.folderName) })
        XCTAssertTrue(scanned.contains { $0.items.contains { $0.title.contains("Oskar asks two suppliers") } })
    }
}
