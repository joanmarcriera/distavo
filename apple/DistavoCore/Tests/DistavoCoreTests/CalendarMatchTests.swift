// CalendarMatchTests - calendar-aware titling and attendees (Vikunja #2946):
// matching rules, title sanitising, base prediction, sidecar moves, attendee
// cleaning, config migration and the pipeline / regenerate fixtures.
import XCTest
@testable import DistavoCore

final class CalendarMatchTests: XCTestCase {

    // MARK: Helpers

    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)   // an arbitrary instant
    private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }
    private func ev(_ title: String, _ s: Double, _ e: Double, allDay: Bool = false,
                    attendees: [String] = [], cal: String = "c1",
                    status: CalendarEventStatus = .normal) -> CalendarCandidate {
        CalendarCandidate(title: title, start: at(s), end: at(e), isAllDay: allDay,
                          attendees: attendees, calendarID: cal, status: status)
    }
    private func best(_ s: Double, _ e: Double, _ c: [CalendarCandidate],
                      ids: [String] = [], owner: String = "") -> CalendarMatch? {
        CalendarMatcher.best(recordingStart: at(s), recordingEnd: at(e), candidates: c,
                             calendarIDs: ids, ownerName: owner)
    }
    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("distavo-cal-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: Matching rules

    func testFullOverlapMatches() {
        XCTAssertEqual(best(0, 60, [ev("Standup", 0, 60)])?.title, "Standup")
        XCTAssertEqual(best(0, 60, [ev("Reunió d'equip", 0, 60)])?.title, "Reunió d'equip", "the real title keeps its accents")
    }

    func testNoCandidatesOrEmptyRecordingIsNil() {
        XCTAssertNil(best(0, 60, []))
        XCTAssertNil(best(10, 10, [ev("X", 0, 60)]))
        XCTAssertNil(best(20, 10, [ev("X", 0, 60)]))
    }

    func testOverlapThresholdIsMaxOfFiveMinutesAndHalfTheShorter() {
        // 60-min recording, 60-min event: needs 30 min.
        XCTAssertNil(best(0, 60, [ev("A", 31, 91)]), "29 min of overlap is below 50 % of 60")
        XCTAssertNotNil(best(0, 60, [ev("A", 30, 90)]), "exactly 30 min qualifies")
        // Short event inside the recording: 50 % of the SHORTER (the event, 20 min) = 10 min.
        XCTAssertNotNil(best(0, 60, [ev("Quick sync", 20, 40)]))
        // 4-min event fully inside a 12-min recording: overlap 4 min < 5-min floor.
        XCTAssertNil(best(0, 12, [ev("Tiny", 4, 8)]))
        // 5-min event fully inside: exactly the floor.
        XCTAssertNotNil(best(0, 12, [ev("Five", 4, 9)]))
        // Qualifies on overlap but is a small part of a long recording: score below the minimum.
        XCTAssertNil(best(0, 120, [ev("Quick sync", 50, 70)]))
        // Touching only at the edge.
        XCTAssertNil(best(0, 60, [ev("Later", 60, 120)]))
    }

    func testLongBlockDoesNotBeatTheRealMeeting() {
        // 14:00-14:30 meeting recorded 13:58-14:33; a 9-17 "Focus" block overlaps 35 min, the meeting 30.
        // Minutes after 09:00: Focus 0-480, meeting 300-330, recording 298-333.
        let f = ev("Focus", 0, 480), m = ev("Real meeting", 300, 330)
        XCTAssertEqual(best(298, 333, [f, m])?.title, "Real meeting")
        XCTAssertEqual(best(298, 333, [m, f])?.title, "Real meeting")
        XCTAssertNil(best(298, 333, [f]), "a huge block alone is NOT used (score 35/480)")
    }

    func testAllDayDeclinedCancelledAndEmptyTitlesAreIgnored() {
        XCTAssertNil(best(0, 60, [ev("Holiday", 0, 60, allDay: true)]))
        XCTAssertNil(best(0, 60, [ev("No", 0, 60, status: .declined)]))
        XCTAssertNil(best(0, 60, [ev("Gone", 0, 60, status: .cancelled)]))
        XCTAssertNil(best(0, 60, [ev("   ", 0, 60)]))
        XCTAssertNil(best(0, 60, [ev("\u{200B}\n", 0, 60)]))
        // An ignored event never shadows a real one.
        XCTAssertEqual(best(0, 60, [ev("Holiday", 0, 60, allDay: true), ev("Real", 5, 60)])?.title, "Real")
    }

    func testLargestOverlapWinsAndTieGoesToClosestStart() {
        XCTAssertEqual(best(0, 60, [ev("Small", 0, 40), ev("Big", 0, 60)])?.title, "Big")
        // Same 30-min overlap; starts 10 and 0 minutes from the recording start (10:00 vs 10:10).
        let a = ev("Starts-late", 10, 40), b = ev("Starts-on-time", 0, 30)
        XCTAssertEqual(best(0, 60, [a, b])?.title, "Starts-on-time")
        XCTAssertEqual(best(0, 60, [b, a])?.title, "Starts-on-time", "order must not matter")
    }

    func testBackToBackMeetings() {
        // Recording starts a little into the first meeting and runs into the second.
        let first = ev("First", 0, 30), second = ev("Second", 30, 90)
        XCTAssertEqual(best(25, 85, [first, second])?.title, "Second", "55 of 60 min inside Second, 5 inside First")
        XCTAssertEqual(best(5, 28, [first, second])?.title, "First")
    }

    func testRecordingSpanningTwoEventsPicksTheLargerOverlap() {
        // 10:00-11:30 recording over 10:00-10:30 and 10:30-11:30.
        XCTAssertEqual(best(0, 90, [ev("A", 0, 30), ev("B", 30, 90)])?.title, "B")
        // Equal overlaps (45/45), tie -> the one starting at the recording start.
        XCTAssertEqual(best(0, 90, [ev("B", 45, 90), ev("A", 0, 45)])?.title, "A")
    }

    func testCalendarFilter() {
        let c = [ev("Work", 0, 60, cal: "work"), ev("Home", 0, 60, cal: "home")]
        XCTAssertEqual(best(0, 60, c, ids: ["home"])?.title, "Home")
        XCTAssertNil(best(0, 60, c, ids: ["other"]))
        XCTAssertNotNil(best(0, 60, c, ids: []), "empty list means all calendars")
    }

    func testMatchCarriesCleanedAttendeesAndTitle() {
        let m = best(0, 60, [ev("  Roadmap \n review ", 0, 60, attendees: ["Ada", "Me", "ada", "x@y.com"])], owner: "Me")
        XCTAssertEqual(m?.title, "Roadmap review")
        XCTAssertEqual(m?.attendees, ["Ada"])
    }

    // MARK: Title sanitising

    func testFileNameComponentBasics() {
        XCTAssertEqual(CalendarTitle.fileNameComponent("Weekly sync"), "Weekly sync")
        XCTAssertEqual(CalendarTitle.fileNameComponent("Q3/Q4: plan\\draft"), "Q3-Q4- plan-draft")
        XCTAssertEqual(CalendarTitle.fileNameComponent("  a   b\tc  "), "a b c")
        XCTAssertEqual(CalendarTitle.fileNameComponent("Reunió d'equip 🎉"), "Reunio d equip")
        XCTAssertEqual(CalendarTitle.fileNameComponent("Reunió d’equip"), "Reunio dequip", "typographic apostrophe removed")
        XCTAssertEqual(CalendarTitle.fileNameComponent("Revisió de l·lèxic — ñandú, façade"), "Revisio de llexic - nandu, facade")
        XCTAssertEqual(CalendarTitle.fileNameComponent("A – B"), "A - B")
        XCTAssertEqual(CalendarTitle.fileNameComponent("Straße Œuvre"), "Strasse OEuvre")
    }

    func testHostileTitles() {
        for hostile in ["../../etc/passwd", "/absolute/path", "..", "...", ".hidden", "trail. . ",
                        "a\u{0}b", "line1\nline2\r\nline3", "\u{202E}rtl", "con:\\x", "~/Library", "."] {
            let out = CalendarTitle.fileNameComponent(hostile)
            if let out {
                XCTAssertFalse(out.contains("/"), hostile)
                XCTAssertFalse(out.contains("\\"), hostile)
                XCTAssertFalse(out.contains(":"), hostile)
                XCTAssertFalse(out.hasPrefix("."), hostile)
                XCTAssertFalse(out.hasSuffix("."), hostile)
                XCTAssertFalse(out.hasSuffix(" "), hostile)
                XCTAssertFalse(out.unicodeScalars.contains { $0.value < 0x20 }, hostile)
            }
        }
        XCTAssertNil(CalendarTitle.fileNameComponent(".."))
        XCTAssertNil(CalendarTitle.fileNameComponent("..."))
        XCTAssertNil(CalendarTitle.fileNameComponent(" . "))
        XCTAssertNil(CalendarTitle.fileNameComponent("\u{0}\u{1}"))
        for nonLatin in ["会議のタイトル", "פגישת צוות", "Встреча", "—–-", "🎉🎉", "·’"] {
            XCTAssertNil(CalendarTitle.fileNameComponent(nonLatin), nonLatin)
        }
        XCTAssertEqual(CalendarTitle.fileNameComponent("会議 Q3"), "Q3")
        XCTAssertEqual(CalendarTitle.fileNameComponent(".hidden"), "hidden")
        XCTAssertEqual(CalendarTitle.fileNameComponent("trail. . "), "trail")
        XCTAssertEqual(CalendarTitle.fileNameComponent("line1\nline2"), "line1 line2")
        XCTAssertEqual(CalendarTitle.fileNameComponent("/x"), "-x")
    }

    func testUTF8ByteCapIsOnACharacterBoundary() {
        let long = String(repeating: "é", count: 200)             // folds to ASCII e
        let out = CalendarTitle.fileNameComponent(long)!
        XCTAssertEqual(out.utf8.count, CalendarTitle.maxFileNameBytes)
        XCTAssertTrue(out.allSatisfy { $0 == "e" })
        XCTAssertNil(CalendarTitle.fileNameComponent(String(repeating: "🎉", count: 100)), "no Latin letters: no rename")
        // Cutting can expose a trailing space/dot: it must be trimmed afterwards.
        let tricky = String(repeating: "a", count: 119) + " bcd"   // ASCII already
        XCTAssertEqual(CalendarTitle.fileNameComponent(tricky), String(repeating: "a", count: 119))
    }

    func testRecordingStemUsesTheLocalDate() {
        let tz = TimeZone(identifier: "Pacific/Auckland")!   // UTC+13 in October
        var comps = DateComponents(); comps.year = 2026; comps.month = 10; comps.day = 5; comps.hour = 23; comps.minute = 30
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
        let date = utc.date(from: comps)!                        // 2026-10-05 23:30 UTC = 2026-10-06 12:30 NZDT
        XCTAssertEqual(CalendarTitle.recordingStem(date: date, title: "Event Title", timeZone: tz), "2026-10-06 Event Title")
        XCTAssertEqual(CalendarTitle.recordingStem(date: date, title: "Event Title", timeZone: TimeZone(identifier: "UTC")!),
                       "2026-10-05 Event Title")
        XCTAssertNil(CalendarTitle.recordingStem(date: date, title: "...", timeZone: tz))
    }

    func testPredictedBaseEqualsBaseForOfTheRenamedFile() {
        let dir = URL(fileURLWithPath: "/tmp/recs")
        let titles = ["Event Title", "Q3/Q4: plan", "Reunió d'equip 🎉", "Weekly - sync.", "a  b",
                      "Trailing dash -", String(repeating: "x", count: 300), "(1:1) Marc & Ada", "Revisió l·lèxica — ñ ç"]
        for t in titles {
            guard let stem = CalendarTitle.recordingStem(date: t0, title: t) else { XCTFail(t); continue }
            let url = dir.appendingPathComponent("\(stem).wav")
            XCTAssertEqual(CalendarTitle.predictedBase(stem: stem),
                           DistavoState.baseFor(recordingsDir: dir, path: url), t)
        }
        // Documented: spaces in the file name become underscores in the base,
        // so the note is `2026-10-05_Event_Title.md`.
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
        let d = utc.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 12))!
        let stem = CalendarTitle.recordingStem(date: d, title: "Event Title", timeZone: TimeZone(identifier: "UTC")!)!
        XCTAssertEqual(stem, "2026-10-05 Event Title")
        XCTAssertEqual(CalendarTitle.predictedBase(stem: stem), "2026-10-05_Event_Title")
    }

    func testRetitle() {
        let note = "# Meeting notes\n\n## Summary\nbody\n"
        XCTAssertEqual(CalendarTitle.retitle(note: note, title: "Board review"), "# Board review\n\n## Summary\nbody\n")
        XCTAssertEqual(CalendarTitle.retitle(note: "## no h1\n", title: "X"), "## no h1\n")
        XCTAssertEqual(CalendarTitle.retitle(note: note, title: "  "), note)
        XCTAssertEqual(CalendarTitle.retitle(note: "# A\n# B\n", title: "T"), "# T\n# B\n", "only the first heading")
    }

    // MARK: Attendees

    func testAttendeeCleaning() {
        let out = CalendarAttendees.clean(
            ["Ada Lovelace", "mailto:grace@x.org", "ada lovelace", "ADA  LOVELACE", "bob@x.org", "  ", "Zoë", "Zoe",
             "Joan Marc Riera Duocastella", "Marc Smith"],
            owner: "Joan Marc Riera")
        XCTAssertEqual(out, ["Ada Lovelace", "Zoë", "Marc Smith"])
    }

    func testOwnerRemovalRules() {
        XCTAssertEqual(CalendarAttendees.clean(["Marc", "Marc Smith"], owner: "Marc"), ["Marc Smith"],
                       "single-word owner matches exactly only")
        XCTAssertEqual(CalendarAttendees.clean(["Marc Riera"], owner: "marc riera"), [])
        XCTAssertEqual(CalendarAttendees.clean(["Me"], owner: "Me"), [])
        XCTAssertEqual(CalendarAttendees.clean(["Ada"], owner: ""), ["Ada"])
    }

    func testAttendeeCap() {
        let many = (1...40).map { "Person \($0)" }
        XCTAssertEqual(CalendarAttendees.clean(many, owner: "").count, 15)
        XCTAssertEqual(CalendarAttendees.clean(many, owner: "", cap: 3), ["Person 1", "Person 2", "Person 3"])
    }

    func testMergedParticipants() {
        XCTAssertEqual(CalendarAttendees.mergedParticipants(existing: nil, attendees: ["Ada", "Bo"]),
                       "Other participants: Ada, Bo")
        XCTAssertEqual(CalendarAttendees.mergedParticipants(existing: "Other participants: ada", attendees: ["Ada"]),
                       "Other participants: ada", "already mentioned: untouched")
        XCTAssertEqual(CalendarAttendees.mergedParticipants(existing: "Me (me): host", attendees: ["Ada"]),
                       "Me (me): host. Other participants: Ada")
        XCTAssertEqual(CalendarAttendees.mergedParticipants(existing: "x", attendees: []), "x")
        XCTAssertNil(CalendarAttendees.mergedParticipants(existing: nil, attendees: []))
    }

    // MARK: Sidecar store

    func testSidecarRoundTripAndVersioning() throws {
        let dir = tempDir()
        let m = CalendarMatch(title: "Event Title", start: at(0), end: at(60), attendees: ["Ada"])
        try CalendarMatchStore.save(m, workDir: dir, base: "b")
        XCTAssertEqual(CalendarMatchStore.load(workDir: dir, base: "b"), m)
        XCTAssertNil(CalendarMatchStore.load(workDir: dir, base: "missing"))
        let json = try String(contentsOf: CalendarMatchStore.url(workDir: dir, base: "b"), encoding: .utf8)
        XCTAssertTrue(json.contains("\"version\" : 1"))
        // A newer format is ignored, never half-read; corrupt files too.
        try json.replacingOccurrences(of: "\"version\" : 1", with: "\"version\" : 99")
            .write(to: CalendarMatchStore.url(workDir: dir, base: "b"), atomically: true, encoding: .utf8)
        XCTAssertNil(CalendarMatchStore.load(workDir: dir, base: "b"))
        try "not json".write(to: CalendarMatchStore.url(workDir: dir, base: "b"), atomically: true, encoding: .utf8)
        XCTAssertNil(CalendarMatchStore.load(workDir: dir, base: "b"))
    }

    // MARK: Sidecar moves

    private func touch(_ url: URL, _ text: String = "x") throws { try text.write(to: url, atomically: true, encoding: .utf8) }
    private func names(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    func testMoveSidecarsMovesEveryFileKeyedOnTheOldBase() throws {
        let work = tempDir()
        for s in ["scratchpad.json", "speakers.json", "language.json", "calendar.json", "futurething.dat"] {
            try touch(work.appendingPathComponent("old.\(s)"))
        }
        try touch(work.appendingPathComponent("other.speakers.json"))
        try touch(work.appendingPathComponent("older.speakers.json"))        // prefix of the name but not the base
        try RecordingBookmarks(marks: [.init(offsetSeconds: 3)], source: "old.wav")
            .save(workDir: work, base: "old")
        try CalendarRename.moveSidecars(workDir: work, oldBase: "old", newBase: "new",
                                        oldSource: "old.wav", newSource: "New Name.wav")
        XCTAssertEqual(names(work), ["new.bookmarks.json", "new.calendar.json", "new.futurething.dat", "new.language.json",
                                     "new.scratchpad.json", "new.speakers.json", "older.speakers.json", "other.speakers.json"])
        XCTAssertEqual(RecordingBookmarks.load(workDir: work, base: "new")?.source, "New Name.wav")
    }

    func testMoveSidecarsFailureRollsBackEverything() throws {
        let work = tempDir()
        for s in ["a.json", "b.json", "c.json"] { try touch(work.appendingPathComponent("old.\(s)"), s) }
        try RecordingBookmarks(marks: [.init(offsetSeconds: 3)], source: "old.wav").save(workDir: work, base: "old")
        let before = names(work)
        var calls = 0
        struct Boom: Error {}
        var steps = CalendarRename.Steps()
        steps.copy = { from, to in
            calls += 1
            if calls == 3 { throw Boom() }
            try FileManager.default.copyItem(at: from, to: to)
        }
        XCTAssertThrowsError(try CalendarRename.moveSidecars(
            workDir: work, oldBase: "old", newBase: "new", oldSource: "old.wav", newSource: "new.wav", steps: steps))
        XCTAssertEqual(names(work), before, "the copies were removed, the originals untouched")
        XCTAssertEqual(RecordingBookmarks.load(workDir: work, base: "old")?.source, "old.wav")
        XCTAssertEqual(try String(contentsOf: work.appendingPathComponent("old.b.json")), "b.json")
    }

    /// What startup recovery would do at an instant: finalise the `.wav.part` under its own name and
    /// look for its sidecars under THAT base. Consistent = the full sidecar set is there.
    private func recoveryState(rec: URL, work: URL, sidecars: [String]) -> (base: String, complete: Bool)? {
        guard let partName = names(rec).first(where: { $0.hasSuffix(".wav.part") }) else { return nil }
        let wav = rec.appendingPathComponent(String(partName.dropLast(5)))
        let base = DistavoState.baseFor(recordingsDir: rec, path: wav)
        return (base, sidecars.allSatisfy { FileManager.default.fileExists(atPath: work.appendingPathComponent("\(base).\($0)").path) })
    }

    func testPartAndSidecarsMoveTogetherAndRecoveryIsConsistentAtEveryInstant() throws {
        let root = tempDir()
        let rec = root.appendingPathComponent("recs"), work = root.appendingPathComponent("work"), notes = root.appendingPathComponent("notes")
        for d in [rec, work, notes] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        let original = rec.appendingPathComponent("Meeting 2026-10-05 10.00.00.wav")
        let part = URL(fileURLWithPath: original.path + ".part")
        try touch(part, "audio")
        let oldBase = DistavoState.baseFor(recordingsDir: rec, path: original)
        let sidecars = ["scratchpad.json", "speakers.json", "bookmarks.json", "language.json"]
        for sc in sidecars { try touch(work.appendingPathComponent("\(oldBase).\(sc)"), sc) }
        let match = CalendarMatch(title: "Event Title", start: at(0), end: at(60))
        let utc = TimeZone(identifier: "UTC")!
        var utcCal = Calendar(identifier: .gregorian); utcCal.timeZone = utc
        let start = utcCal.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 10))!

        var snapshots: [(String, (base: String, complete: Bool)?)] = []
        var steps = CalendarRename.Steps()
        steps.copy = { from, to in
            snapshots.append(("before copy", self.recoveryState(rec: rec, work: work, sidecars: sidecars)))
            try FileManager.default.copyItem(at: from, to: to)
        }
        steps.commit = { from, to in
            snapshots.append(("before commit", self.recoveryState(rec: rec, work: work, sidecars: sidecars)))
            try FileManager.default.moveItem(at: from, to: to)
        }
        steps.afterCommit = {
            snapshots.append(("after commit", self.recoveryState(rec: rec, work: work, sidecars: sidecars)))
        }
        let target = CalendarRename.prepare(recording: original, match: match, recordingStart: start, recordingsDir: rec,
                                            workDir: work, notesDir: notes, timeZone: utc, steps: steps)
        XCTAssertEqual(target?.lastPathComponent, "2026-10-05 Event Title.wav")
        for (when, state) in snapshots {
            XCTAssertEqual(state?.complete, true, "crash \(when): the part has all sidecars under its own base")
        }
        XCTAssertEqual(snapshots.last?.1?.base, "2026-10-05_Event_Title", "after the commit recovery uses the new name")
        XCTAssertEqual(snapshots.first?.1?.base, oldBase)
        XCTAssertEqual(names(rec), ["2026-10-05 Event Title.wav.part"])
        XCTAssertFalse(names(work).contains { $0.hasPrefix(oldBase + ".") }, "old sidecars cleaned up")
    }

    func testFailureBeforeDuringAndAtCommitLeavesTheOriginalConsistent() throws {
        for failAt in ["copy", "commit"] {
            let root = tempDir()
            let rec = root.appendingPathComponent("recs"), work = root.appendingPathComponent("work"), notes = root.appendingPathComponent("notes")
            for d in [rec, work, notes] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
            let original = rec.appendingPathComponent("Meeting 2026-10-05 10.00.00.wav")
            try touch(URL(fileURLWithPath: original.path + ".part"), "audio")
            let oldBase = DistavoState.baseFor(recordingsDir: rec, path: original)
            let sidecars = ["scratchpad.json", "speakers.json"]
            for sc in sidecars { try touch(work.appendingPathComponent("\(oldBase).\(sc)"), sc) }
            struct Boom: Error {}
            var steps = CalendarRename.Steps()
            if failAt == "copy" {
                var n = 0
                steps.copy = { from, to in n += 1; if n == 2 { throw Boom() }; try FileManager.default.copyItem(at: from, to: to) }
            } else {
                steps.commit = { _, _ in throw Boom() }
            }
            let r = CalendarRename.prepare(recording: original, match: CalendarMatch(title: "T", start: at(0), end: at(60)),
                                           recordingStart: t0, recordingsDir: rec, workDir: work, notesDir: notes, steps: steps)
            XCTAssertNil(r, failAt)
            XCTAssertEqual(names(rec), ["Meeting 2026-10-05 10.00.00.wav.part"], failAt)
            XCTAssertEqual(names(work), sidecars.map { "\(oldBase).\($0)" }.sorted(), "\(failAt): no stray copies")
        }
    }

    func testMoveSidecarsRefusesToOverwrite() throws {
        let work = tempDir()
        try touch(work.appendingPathComponent("old.a.json"), "old")
        try touch(work.appendingPathComponent("old.b.json"), "oldb")
        try touch(work.appendingPathComponent("new.b.json"), "keep")
        XCTAssertThrowsError(try CalendarRename.moveSidecars(
            workDir: work, oldBase: "old", newBase: "new", oldSource: "o", newSource: "n"))
        XCTAssertEqual(try String(contentsOf: work.appendingPathComponent("new.b.json")), "keep")
        XCTAssertEqual(names(work), ["new.b.json", "old.a.json", "old.b.json"], "rolled back")
    }

    func testPrepareRenamesWithUniqueNameAndKeepsOriginalOnFailure() throws {
        let root = tempDir()
        let rec = root.appendingPathComponent("recs"), work = root.appendingPathComponent("work"), notes = root.appendingPathComponent("notes")
        for d in [rec, work, notes] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        let original = rec.appendingPathComponent("Meeting 2026-10-05 10.00.00.wav")
        let oldBase = DistavoState.baseFor(recordingsDir: rec, path: original)
        try touch(work.appendingPathComponent("\(oldBase).scratchpad.json"))
        try touch(work.appendingPathComponent("\(oldBase).speakers.json"))
        let match = CalendarMatch(title: "Event Title", start: at(0), end: at(60))
        let utc = TimeZone(identifier: "UTC")!
        var utcCal = Calendar(identifier: .gregorian); utcCal.timeZone = utc
        let start = utcCal.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 10))!

        let first = CalendarRename.prepare(recording: original, match: match, recordingStart: start,
                                           recordingsDir: rec, workDir: work, notesDir: notes, timeZone: utc)
        XCTAssertEqual(first?.lastPathComponent, "2026-10-05 Event Title.wav")
        XCTAssertEqual(names(work), ["2026-10-05_Event_Title.scratchpad.json", "2026-10-05_Event_Title.speakers.json"])
        XCTAssertEqual(DistavoState.baseFor(recordingsDir: rec, path: first!), "2026-10-05_Event_Title")

        // Same title again: the first take's sidecars occupy the base -> "… 2".
        let original2 = rec.appendingPathComponent("Meeting 2026-10-05 11.00.00.wav")
        let ob2 = DistavoState.baseFor(recordingsDir: rec, path: original2)
        try touch(work.appendingPathComponent("\(ob2).bookmarks.json"))
        let second = CalendarRename.prepare(recording: original2, match: match, recordingStart: start,
                                            recordingsDir: rec, workDir: work, notesDir: notes, timeZone: utc)
        XCTAssertEqual(second?.lastPathComponent, "2026-10-05 Event Title 2.wav")
        XCTAssertTrue(names(work).contains("2026-10-05_Event_Title_2.bookmarks.json"))

        // A note already using the base also forces a new name.
        try touch(notes.appendingPathComponent("2026-10-05_Event_Title_3.md"))
        let original3 = rec.appendingPathComponent("Meeting 2026-10-05 12.00.00.wav")
        let third = CalendarRename.prepare(recording: original3, match: match, recordingStart: start,
                                           recordingsDir: rec, workDir: work, notesDir: notes, timeZone: utc)
        XCTAssertEqual(third?.lastPathComponent, "2026-10-05 Event Title 4.wav")

        // Failure: nothing renamed, nothing moved.
        let original4 = rec.appendingPathComponent("Meeting 2026-10-05 13.00.00.wav")
        let ob4 = DistavoState.baseFor(recordingsDir: rec, path: original4)
        try touch(work.appendingPathComponent("\(ob4).speakers.json"))
        struct Boom: Error {}
        let m4 = CalendarMatch(title: "Other", start: at(0), end: at(60))
        let failed = CalendarRename.prepare(recording: original4, match: m4, recordingStart: start,
                                            recordingsDir: rec, workDir: work, notesDir: notes, timeZone: utc,
                                            steps: { var st = CalendarRename.Steps(); st.copy = { _, _ in throw Boom() }; return st }())
        XCTAssertNil(failed)
        XCTAssertTrue(names(work).contains("\(ob4).speakers.json"))
        // An unusable title keeps the original name too.
        XCTAssertNil(CalendarRename.prepare(recording: original4, match: CalendarMatch(title: "...", start: at(0), end: at(1)),
                                            recordingStart: start, recordingsDir: rec, workDir: work, notesDir: notes))
    }

    // MARK: Config migration

    private func decode(_ json: String) throws -> Config {
        try JSONDecoder().decode(Config.self, from: Data(json.utf8))
    }

    func testConfigPredatingTheSectionIsOff() throws {
        let c = try decode("{}").calendar
        XCTAssertFalse(c.enabled)
        XCTAssertFalse(c.renameRecordings)
        XCTAssertTrue(c.attendeesAsParticipants)
        XCTAssertEqual(c.calendars, [])
        XCTAssertEqual(c, CalendarConfig())
        XCTAssertEqual(Config().calendar, CalendarConfig())
        XCTAssertFalse(Config.recommendedForThisMac().calendar.enabled, "off on fresh installs too")
        XCTAssertFalse(Config.recommendedForThisMac().calendar.renameRecordings)
    }

    func testPartialWrongTypedAndRoundTrip() throws {
        let p = try decode(#"{"calendar":{"enabled":true,"calendars":["a","b"]}}"#).calendar
        XCTAssertTrue(p.enabled); XCTAssertFalse(p.renameRecordings); XCTAssertEqual(p.calendars, ["a", "b"])
        let bad = try decode(#"{"calendar":{"enabled":"yes","calendars":5,"rename_recordings":1}}"#).calendar
        XCTAssertEqual(bad, CalendarConfig())
        let notObject = try decode(#"{"calendar":7,"min_recording_seconds":42}"#)
        XCTAssertEqual(notObject.calendar, CalendarConfig())
        XCTAssertEqual(notObject.minRecordingSeconds, 42)
        var cfg = Config()
        cfg.calendar = CalendarConfig(enabled: true, renameRecordings: true, attendeesAsParticipants: false, calendars: ["x"])
        let back = try JSONDecoder().decode(Config.self, from: try JSONEncoder().encode(cfg))
        XCTAssertEqual(back.calendar, cfg.calendar)
        let raw = String(decoding: try JSONEncoder().encode(cfg), as: UTF8.self)
        XCTAssertTrue(raw.contains("rename_recordings") && raw.contains("attendees_as_participants"))
    }

    // MARK: Pipeline fixtures

    private struct Env { var config: Config; var recordings: URL; var work: URL; var notes: URL }

    private func makeEnv(calendar: CalendarConfig = CalendarConfig(enabled: true)) throws -> Env {
        let root = tempDir()
        let rec = root.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: rec, withIntermediateDirectories: true)
        var cfg = Config()
        cfg.recordingsDir = rec.path
        cfg.notesDir = root.appendingPathComponent("notes").path
        cfg.workDir = root.appendingPathComponent("work").path
        cfg.calendar = calendar
        return Env(config: cfg, recordings: rec, work: root.appendingPathComponent("work"),
                   notes: root.appendingPathComponent("notes"))
    }

    private final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var _prompts: [String] = []
        private var _lookups = 0
        func add(_ p: String) { lock.lock(); _prompts.append(p); lock.unlock() }
        func lookup() { lock.lock(); _lookups += 1; lock.unlock() }
        var prompts: [String] { lock.lock(); defer { lock.unlock() }; return _prompts }
        var lookups: Int { lock.lock(); defer { lock.unlock() }; return _lookups }
    }

    /// Local time 2026-10-05 `hour:minute`, matching how the recorder's file name is read.
    private func local(_ hour: Int, _ minute: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: hour, minute: minute))!
    }

    private func deps(_ seen: Seen, events: [CalendarCandidate]?, seconds: Double? = 3600) -> PipelineDeps {
        PipelineDeps(
            convertToWav: { _, dest in
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data([0]).write(to: dest)
            },
            transcribe: { _, _ in ["segments": [["speaker": "SPEAKER_00", "text": "hello world"]]] },
            ollamaReachable: { _ in true },
            summarise: { transcript, _, _, context in
                seen.add(context.prompt(transcript: transcript))
                return PipelineTests.validNote
            },
            audioDurationSeconds: { _ in seconds },
            calendarLookup: events.map { list in { _, _ in seen.lookup(); return list } })
    }

    private func recording(_ env: Env, _ name: String = "Meeting 2026-10-05 10.00.00.wav") throws -> URL {
        let url = env.recordings.appendingPathComponent(name)
        try Data([0, 1, 2, 3]).write(to: url)
        return url
    }

    private let standup = { (s: Date, e: Date) in
        CalendarCandidate(title: "Event Title", start: s, end: e, attendees: ["Ada Lovelace", "Me", "Grace Hopper"])
    }

    func testMatchGivesTitleAndAttendeesInPromptAndSidecars() async throws {
        let env = try makeEnv()
        let url = try recording(env)
        let base = DistavoState.baseFor(recordingsDir: env.recordings, path: url)
        let seen = Seen()
        let r = await Pipeline.processOne(path: url, config: env.config,
                                          deps: deps(seen, events: [standup(local(10), local(11))]),
                                          stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(r.status, .done, r.message)
        let note = try String(contentsOf: env.notes.appendingPathComponent("\(base).md"), encoding: .utf8)
        XCTAssertTrue(note.hasPrefix("# Event Title\n"), note)
        XCTAssertFalse(note.contains("# Meeting notes"))
        XCTAssertTrue(seen.prompts[0].contains("Other participants: Ada Lovelace, Grace Hopper"), "attendees reached Prompt.build")
        XCTAssertFalse(seen.prompts[0].contains("Me,"), "owner removed")
        let stored = CalendarMatchStore.load(workDir: env.work, base: base)
        XCTAssertEqual(stored?.title, "Event Title")
        XCTAssertEqual(stored?.attendees, ["Ada Lovelace", "Grace Hopper"])
        // Attendees also become speaker hints so the frontmatter (#2954) sees them.
        XCTAssertEqual(SpeakerHints.load(workDir: env.work, base: base)?.participants,
                       "Other participants: Ada Lovelace, Grace Hopper")
    }

    func testExistingSpeakerHintsAreNotReplacedButGetMissingAttendees() async throws {
        let env = try makeEnv()
        let url = try recording(env)
        let base = DistavoState.baseFor(recordingsDir: env.recordings, path: url)
        try SpeakerHints(count: 3, participants: "Other participants: Ada Lovelace").save(workDir: env.work, base: base)
        let seen = Seen()
        _ = await Pipeline.processOne(path: url, config: env.config,
                                      deps: deps(seen, events: [standup(local(10), local(11))]),
                                      stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(SpeakerHints.load(workDir: env.work, base: base)?.participants, "Other participants: Ada Lovelace")
        XCTAssertTrue(seen.prompts[0].contains("Other participants: Ada Lovelace. Other participants: Grace Hopper"))
    }

    func testAttendeesAsParticipantsOffKeepsTitleOnly() async throws {
        let env = try makeEnv(calendar: CalendarConfig(enabled: true, attendeesAsParticipants: false))
        let url = try recording(env)
        let base = DistavoState.baseFor(recordingsDir: env.recordings, path: url)
        let seen = Seen()
        _ = await Pipeline.processOne(path: url, config: env.config,
                                      deps: deps(seen, events: [standup(local(10), local(11))]),
                                      stableChecks: 1, stableDelay: 0)
        XCTAssertFalse(seen.prompts[0].contains("Ada Lovelace"))
        XCTAssertNil(SpeakerHints.load(workDir: env.work, base: base))
        let note = try String(contentsOf: env.notes.appendingPathComponent("\(base).md"), encoding: .utf8)
        XCTAssertTrue(note.hasPrefix("# Event Title"))
    }

    /// The reference run: calendar section absent from the config altogether.
    private func baseline(_ name: String = "Meeting 2026-10-05 10.00.00.wav") async throws -> (note: String, prompt: String) {
        let env = try makeEnv(calendar: CalendarConfig())
        let url = try recording(env, name)
        let seen = Seen()
        _ = await Pipeline.processOne(path: url, config: env.config, deps: deps(seen, events: nil),
                                      stableChecks: 1, stableDelay: 0)
        let base = DistavoState.baseFor(recordingsDir: env.recordings, path: url)
        return (try String(contentsOf: env.notes.appendingPathComponent("\(base).md"), encoding: .utf8), seen.prompts[0])
    }

    func testFeatureOffIsByteIdenticalAndNeverLooksUp() async throws {
        let ref = try await baseline()
        let env = try makeEnv(calendar: CalendarConfig(enabled: false))
        let url = try recording(env)
        let seen = Seen()
        _ = await Pipeline.processOne(path: url, config: env.config,
                                      deps: deps(seen, events: [standup(local(10), local(11))]),
                                      stableChecks: 1, stableDelay: 0)
        let base = DistavoState.baseFor(recordingsDir: env.recordings, path: url)
        let note = try String(contentsOf: env.notes.appendingPathComponent("\(base).md"), encoding: .utf8)
        XCTAssertEqual(note, ref.note)
        XCTAssertEqual(seen.prompts[0], ref.prompt)
        XCTAssertEqual(seen.lookups, 0)
        XCTAssertNil(CalendarMatchStore.load(workDir: env.work, base: base))
        XCTAssertNil(SpeakerHints.load(workDir: env.work, base: base))
    }

    func testNoMatchIsByteIdentical() async throws {
        let ref = try await baseline()
        let env = try makeEnv()
        let url = try recording(env)
        let seen = Seen()
        // An event two hours earlier, a declined one, and an all-day one: nothing qualifies.
        let events = [standup(local(7), local(8)),
                      CalendarCandidate(title: "Declined", start: local(10), end: local(11), status: .declined),
                      CalendarCandidate(title: "Holiday", start: local(0), end: local(23), isAllDay: true)]
        _ = await Pipeline.processOne(path: url, config: env.config, deps: deps(seen, events: events),
                                      stableChecks: 1, stableDelay: 0)
        let base = DistavoState.baseFor(recordingsDir: env.recordings, path: url)
        XCTAssertEqual(try String(contentsOf: env.notes.appendingPathComponent("\(base).md"), encoding: .utf8), ref.note)
        XCTAssertEqual(seen.prompts[0], ref.prompt)
        XCTAssertEqual(seen.lookups, 1)
        XCTAssertNil(CalendarMatchStore.load(workDir: env.work, base: base))
    }

    func testEnabledButNoSeamOrUnknownDurationIsInert() async throws {
        let ref = try await baseline()
        for (events, seconds) in [(nil, 3600.0 as Double?), ([standup(local(10), local(11))], nil)] as [([CalendarCandidate]?, Double?)] {
            let env = try makeEnv()
            let url = try recording(env)
            let seen = Seen()
            _ = await Pipeline.processOne(path: url, config: env.config, deps: deps(seen, events: events, seconds: seconds),
                                          stableChecks: 1, stableDelay: 0)
            let base = DistavoState.baseFor(recordingsDir: env.recordings, path: url)
            XCTAssertEqual(try String(contentsOf: env.notes.appendingPathComponent("\(base).md"), encoding: .utf8), ref.note)
            XCTAssertEqual(seen.prompts[0], ref.prompt)
        }
    }

    func testStoredSidecarWinsOverALookup() async throws {
        let env = try makeEnv()
        let url = try recording(env)
        let base = DistavoState.baseFor(recordingsDir: env.recordings, path: url)
        try CalendarMatchStore.save(CalendarMatch(title: "From recorder", start: local(10), end: local(11), attendees: ["Zed"]),
                                    workDir: env.work, base: base)
        let seen = Seen()
        _ = await Pipeline.processOne(path: url, config: env.config,
                                      deps: deps(seen, events: [standup(local(10), local(11))]),
                                      stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(seen.lookups, 0)
        let note = try String(contentsOf: env.notes.appendingPathComponent("\(base).md"), encoding: .utf8)
        XCTAssertTrue(note.hasPrefix("# From recorder"))
        XCTAssertTrue(seen.prompts[0].contains("Other participants: Zed"))
    }

    func testDroppedFileWithoutRecordingTimeEvidenceIsNeverMatched() async throws {
        let ref = try await baseline("memo.m4a")
        let env = try makeEnv()
        let url = try recording(env, "memo.m4a")      // filesystem dates say "now": that is not evidence
        let seen = Seen()
        let now = Date()
        let events = [CalendarCandidate(title: "Event Title", start: now.addingTimeInterval(-600), end: now.addingTimeInterval(3000),
                                        attendees: ["Ada Lovelace"])]
        _ = await Pipeline.processOne(path: url, config: env.config, deps: deps(seen, events: events),
                                      stableChecks: 1, stableDelay: 0)
        let base = DistavoState.baseFor(recordingsDir: env.recordings, path: url)
        XCTAssertEqual(seen.lookups, 0, "no evidence, no lookup")
        XCTAssertNil(CalendarMatchStore.load(workDir: env.work, base: base))
        XCTAssertNil(SpeakerHints.load(workDir: env.work, base: base))
        XCTAssertEqual(seen.prompts[0], ref.prompt)
        XCTAssertEqual(try String(contentsOf: env.notes.appendingPathComponent("\(base).md"), encoding: .utf8), ref.note)
    }

    func testDroppedFileWithMediaCreationDateIsMatched() async throws {
        let env = try makeEnv()
        let url = try recording(env, "memo.m4a")
        let seen = Seen()
        var d = deps(seen, events: [standup(local(10), local(11))])
        d.recordingStart = { _ in self.local(10) }       // e.g. AVAsset creation metadata
        _ = await Pipeline.processOne(path: url, config: env.config, deps: d, stableChecks: 1, stableDelay: 0)
        let base = DistavoState.baseFor(recordingsDir: env.recordings, path: url)
        XCTAssertEqual(CalendarMatchStore.load(workDir: env.work, base: base)?.title, "Event Title")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "dropped files are never renamed")
    }

    /// main's `meetingDate` name rule, copied verbatim, as the oracle.
    private func mainRule(_ stem: String, _ tz: TimeZone) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = tz; f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        if let range = stem.range(of: #"\d{4}-\d{2}-\d{2} \d{2}\.\d{2}\.\d{2}"#, options: .regularExpression),
           let date = f.date(from: String(stem[range])) { return date }
        return nil
    }

    func testMeetingDateNameShapesMatchMain() {
        let tz = TimeZone(identifier: "Europe/London")!
        let stems = ["Meeting 2026-09-16 16.13.08", "2026-09-16 16.13.08", "voice 2026-09-16 16.13.08 copy",
                     "sub__Meeting_2026-09-16_16.13.08", "sub__Meeting 2026-09-16 16.13.08", "Meeting 2026-09-16 16.13.08 2",
                     "2026-10-05 10.30.00 Standup", "2026-10-05 Event Title", "memo", "Meeting 2026-13-45 99.99.99", ""]
        for stem in stems {
            let url = URL(fileURLWithPath: "/nonexistent/\(stem).wav")
            XCTAssertEqual(Pipeline.meetingDate(for: url, timeZone: tz), mainRule(stem, tz), stem)
            XCTAssertEqual(Pipeline.recorderNameDate(stem, timeZone: tz), mainRule(stem, tz), stem)
        }
        XCTAssertNotNil(Pipeline.meetingDate(for: URL(fileURLWithPath: "/x/2026-09-16 16.13.08.m4a")), "bare name still dated")
    }

    func testLookupEvidenceAcceptsOnlyTheRecordersExactNameOrMediaMetadata() async {
        let exact = ["Meeting 2026-10-05 10.00.00.wav", "/a/b/Meeting 2026-10-05 10.00.00.WAV"]
        for n in exact { XCTAssertNotNil(Pipeline.exactRecorderNameDate(URL(fileURLWithPath: n.hasPrefix("/") ? n : "/x/\(n)")), n) }
        let rejected = ["2026-10-05 10.30.00 Budget.wav", "Meeting 2026-10-05 10.00.00 copy.wav", "x Meeting 2026-10-05 10.00.00.wav",
                        "2026-10-05 10.00.00.wav", "Meeting 2026-10-05 10.00.00.m4a", "Meeting 2026-10-05 10.00.00 2.wav",
                        "Budget 2026-10-05 10.00.00.wav", "Meeting 2026-13-45 99.99.99.wav"]
        for n in rejected {
            XCTAssertNil(Pipeline.exactRecorderNameDate(URL(fileURLWithPath: "/x/\(n)")), n)
            // No such file: no media metadata either, so no evidence at all.
            let ev = await Pipeline.recordingStartEvidence(URL(fileURLWithPath: "/nonexistent/\(n)"))
            XCTAssertNil(ev, n)
        }
        // The permissive prompt rule is unchanged for those same names.
        XCTAssertNotNil(Pipeline.meetingDate(for: URL(fileURLWithPath: "/nonexistent/2026-10-05 10.30.00 Budget.wav")))
    }

    func testTitleLikeFileNameDoesNotDriveALookup() async throws {
        let env = try makeEnv()
        let url = try recording(env, "2026-10-05 10.30.00 Budget.wav")
        let seen = Seen()
        var d = deps(seen, events: [standup(local(10), local(11))])
        d.recordingStart = { await Pipeline.recordingStartEvidence($0) }   // the real evidence rule
        _ = await Pipeline.processOne(path: url, config: env.config, deps: d, stableChecks: 1, stableDelay: 0)
        let base = DistavoState.baseFor(recordingsDir: env.recordings, path: url)
        XCTAssertEqual(seen.lookups, 0)
        XCTAssertNil(CalendarMatchStore.load(workDir: env.work, base: base))
        // The recorder's own name does look up.
        let own = try recording(env, "Meeting 2026-10-05 10.00.00.wav")
        let seen2 = Seen()
        var d2 = deps(seen2, events: [standup(local(10), local(11))])
        d2.recordingStart = { await Pipeline.recordingStartEvidence($0) }
        _ = await Pipeline.processOne(path: own, config: env.config, deps: d2, stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(seen2.lookups, 1)
    }

    func testCalendarRenamedTimeLikeTitleUsesTheSidecarStart() async throws {
        let env = try makeEnv()
        let url = try recording(env, "2026-10-05 10.30.00 Standup.wav")   // renamed file, title looks like a time
        let base = DistavoState.baseFor(recordingsDir: env.recordings, path: url)
        let recStart = local(10)
        try CalendarMatchStore.save(CalendarMatch(title: "10.30.00 Standup", start: recStart, end: local(11),
                                                  recordingStart: recStart), workDir: env.work, base: base)
        final class Box: @unchecked Sendable { var date: Date? }
        let box = Box()
        var d = deps(Seen(), events: nil)
        d.summarise = { _, _, _, ctx in box.date = ctx.meetingDate; return PipelineTests.validNote }
        _ = await Pipeline.processOne(path: url, config: env.config, deps: d, stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(box.date, recStart, "the sidecar's own start, not the 10.30.00 in the title")
    }

    func testProcessingNeverRenamesTheRecording() async throws {
        let env = try makeEnv(calendar: CalendarConfig(enabled: true, renameRecordings: true))
        let url = try recording(env)
        _ = await Pipeline.processOne(path: url, config: env.config,
                                      deps: deps(Seen(), events: [standup(local(10), local(11))]),
                                      stableChecks: 1, stableDelay: 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: Regenerate

    func testRegenerateUsesTheStoredMatchOnlyWhenEnabled() async throws {
        let env = try makeEnv()
        for d in [env.notes, env.work] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        try "SPEAKER_00: hello there".write(to: Pipeline.cachedTranscriptURL(workDir: env.work, base: "demo"),
                                            atomically: true, encoding: .utf8)
        try "# Meeting notes\n\nOLD".write(to: env.notes.appendingPathComponent("demo.md"), atomically: true, encoding: .utf8)
        try CalendarMatchStore.save(CalendarMatch(title: "Board review", start: at(0), end: at(60), attendees: ["Ada"]),
                                    workDir: env.work, base: "demo")

        let seenOn = Seen()
        let on = await Pipeline.regenerate(base: "demo", options: .init(), config: env.config, deps: deps(seenOn, events: nil))
        XCTAssertEqual(on.status, .done, on.message)
        XCTAssertTrue(seenOn.prompts[0].contains("Other participants: Ada"))
        XCTAssertTrue(try String(contentsOf: env.notes.appendingPathComponent("demo.md"), encoding: .utf8).hasPrefix("# Board review\n"))

        // Feature off: byte-identical to a regenerate with no sidecar at all.
        var off = env.config; off.calendar.enabled = false
        let seenOff = Seen()
        _ = await Pipeline.regenerate(base: "demo", options: .init(), config: off, deps: deps(seenOff, events: nil))
        let plain = try makeEnv(calendar: CalendarConfig())
        for d in [plain.notes, plain.work] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        try "SPEAKER_00: hello there".write(to: Pipeline.cachedTranscriptURL(workDir: plain.work, base: "demo"),
                                            atomically: true, encoding: .utf8)
        try "# Meeting notes\n\nOLD".write(to: plain.notes.appendingPathComponent("demo.md"), atomically: true, encoding: .utf8)
        let seenPlain = Seen()
        _ = await Pipeline.regenerate(base: "demo", options: .init(), config: plain.config, deps: deps(seenPlain, events: nil))
        XCTAssertEqual(seenOff.prompts[0], seenPlain.prompts[0])
        XCTAssertEqual(try String(contentsOf: env.notes.appendingPathComponent("demo.md"), encoding: .utf8),
                       try String(contentsOf: plain.notes.appendingPathComponent("demo.md"), encoding: .utf8))
    }
}
