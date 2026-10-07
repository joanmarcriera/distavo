import XCTest
@testable import DistavoCore

/// Notes window (1.18): the note list, what each note has, and why an action is disabled.
final class NotesLibraryTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!

    private func tempDirs() -> (notes: URL, work: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("distavo-noteslib-\(UUID().uuidString)")
        let notes = root.appendingPathComponent("notes")
        let work = root.appendingPathComponent("work")
        try? FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return (notes, work)
    }

    private func write(_ url: URL, _ text: String) {
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func segments() -> TranscriptSegments {
        TranscriptSegments(segments: [
            .init(start: 0, end: 4, text: "hello there", speaker: "SPEAKER_00"),
            .init(start: 4, end: 185, text: "hi", speaker: "SPEAKER_01")])
    }

    /// A note with everything, an old note with only a saved transcript, and one with nothing.
    private func library() throws -> (notes: URL, work: URL) {
        let (notes, work) = tempDirs()
        write(notes.appendingPathComponent("Meeting_2026-10-07_11.18.17.md"), "# Meeting notes\n\nSPEAKER_00 said hello.\n")
        write(work.appendingPathComponent("Meeting_2026-10-07_11.18.17.transcript.clean.txt"), "SPEAKER_00: hello there\nSPEAKER_01: hi\n")
        try segments().save(workDir: work, base: "Meeting_2026-10-07_11.18.17")

        write(notes.appendingPathComponent("Meeting_2026-10-05_10.39.49.md"), "# Meeting notes\n\none two three\n")
        write(work.appendingPathComponent("Meeting_2026-10-05_10.39.49.transcript.clean.txt"), "SPEAKER_00: hola\n")

        write(notes.appendingPathComponent("Roadmap_2026-08-12.md"), "# Roadmap review\n\nplain text\n")
        write(notes.appendingPathComponent("Roadmap_2026-08-12.prev-20261007-104837.md"), "old")
        return (notes, work)
    }

    private func entry(_ base: String, in entries: [NoteEntry]) throws -> NoteEntry {
        try XCTUnwrap(entries.first { $0.base == base })
    }

    // MARK: Listing

    func testEmptyOrMissingFolderListsNothing() {
        let (notes, work) = tempDirs()
        XCTAssertEqual(NotesLibrary.scan(notesDir: notes, workDir: work), [])
        XCTAssertEqual(NotesLibrary.scan(notesDir: notes.appendingPathComponent("absent"), workDir: work), [])
    }

    func testListsNewestMeetingFirstAndSkipsBackups() throws {
        let (notes, work) = try library()
        let entries = NotesLibrary.scan(notesDir: notes, workDir: work, timeZone: utc)
        XCTAssertEqual(entries.map(\.base), ["Meeting_2026-10-07_11.18.17", "Meeting_2026-10-05_10.39.49", "Roadmap_2026-08-12"])
    }

    func testOrderFollowsTheMeetingDateNotTheFileDate() throws {
        // Regenerating an old note rewrites its file; it must not jump to the top.
        let (notes, work) = try library()
        let old = notes.appendingPathComponent("Roadmap_2026-08-12.md")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(3600)], ofItemAtPath: old.path)
        let entries = NotesLibrary.scan(notesDir: notes, workDir: work, timeZone: utc)
        XCTAssertEqual(entries.last?.base, "Roadmap_2026-08-12")
    }

    func testEntryReportsWhatIsOnDisk() throws {
        let (notes, work) = try library()
        let entries = NotesLibrary.scan(notesDir: notes, workDir: work, timeZone: utc)

        let full = try entry("Meeting_2026-10-07_11.18.17", in: entries)
        XCTAssertTrue(full.hasCleanTranscript)
        XCTAssertTrue(full.hasSegments)
        XCTAssertEqual(full.speakerCount, 2)
        XCTAssertEqual(full.durationSeconds, 185)
        XCTAssertEqual(full.versionCount, 1)
        XCTAssertFalse(full.isVariant)
        XCTAssertEqual(full.title, "Meeting 2026-10-07 11.18.17", "a generic heading falls back to the file name")

        let old = try entry("Meeting_2026-10-05_10.39.49", in: entries)
        XCTAssertTrue(old.hasCleanTranscript)
        XCTAssertFalse(old.hasSegments)
        XCTAssertNil(old.durationSeconds)
        XCTAssertEqual(old.wordCount, 6)

        let bare = try entry("Roadmap_2026-08-12", in: entries)
        XCTAssertFalse(bare.hasCleanTranscript)
        XCTAssertFalse(bare.hasSegments)
        XCTAssertEqual(bare.title, "Roadmap review")
        XCTAssertEqual(bare.speakerCount, 0)
    }

    func testEmptyTranscriptFileCountsAsNoTranscript() throws {
        let (notes, work) = tempDirs()
        write(notes.appendingPathComponent("a.md"), "# A\n")
        write(work.appendingPathComponent("a.transcript.clean.txt"), "  \n")
        XCTAssertFalse(try XCTUnwrap(NotesLibrary.scan(notesDir: notes, workDir: work).first).hasCleanTranscript)
    }

    func testVariantsAreRowsAndCountAsVersions() throws {
        let (notes, work) = try library()
        write(notes.appendingPathComponent("Meeting_2026-10-07_11.18.17@large-v3-en.md"), "# Meeting notes\n")
        let entries = NotesLibrary.scan(notesDir: notes, workDir: work, timeZone: utc)
        let parent = try entry("Meeting_2026-10-07_11.18.17", in: entries)
        let variant = try entry("Meeting_2026-10-07_11.18.17@large-v3-en", in: entries)
        XCTAssertEqual(parent.versionCount, 2)
        XCTAssertEqual(variant.versionCount, 2)
        XCTAssertTrue(variant.isVariant)
        XCTAssertEqual(NotesLibrary.availability(.compare, for: parent), .available)
        XCTAssertTrue(NotesLibrary.marks(parent).contains("2 versions"))
        XCTAssertTrue(NotesLibrary.marks(variant).contains("variant"))
    }

    func testCalendarMatchGivesTitleDateAndAsset() throws {
        let (notes, work) = tempDirs()
        write(notes.appendingPathComponent("rec.md"), "# Meeting notes\n")
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        try CalendarMatchStore.save(
            CalendarMatch(title: "Weekly sync", start: start, end: start.addingTimeInterval(1800), recordingStart: start),
            workDir: work, base: "rec")
        let e = try XCTUnwrap(NotesLibrary.scan(notesDir: notes, workDir: work, timeZone: utc).first)
        XCTAssertEqual(e.title, "Weekly sync")
        XCTAssertEqual(e.calendarTitle, "Weekly sync")
        XCTAssertEqual(e.date, start)
        XCTAssertTrue(NotesLibrary.assets(e).contains { $0.text == "Calendar: Weekly sync" && $0.present })
    }

    func testFrontmatterTitleAndDurationAreUsed() throws {
        let (notes, work) = tempDirs()
        write(notes.appendingPathComponent("n.md"), "---\ntitle: Budget review\nduration_minutes: 42\n---\n# Meeting notes\n\nbody words\n")
        let e = try XCTUnwrap(NotesLibrary.scan(notesDir: notes, workDir: work, timeZone: utc).first)
        XCTAssertEqual(e.title, "Budget review")
        XCTAssertEqual(e.durationSeconds, 42 * 60)
        XCTAssertEqual(e.wordCount, 5, "frontmatter is not counted")
        XCTAssertEqual(NotesLibrary.lengthLabel(e), "42 min · 5 words")
    }

    // MARK: Dates

    func testDateInNameUsesTheGivenZone() {
        let utcDate = NotesLibrary.dateInName("Meeting_2026-10-07_11.18.17", timeZone: utc)
        var c = DateComponents(year: 2026, month: 10, day: 7, hour: 11, minute: 18, second: 17)
        c.timeZone = utc
        XCTAssertEqual(utcDate, Calendar(identifier: .gregorian).date(from: c))
        let madrid = NotesLibrary.dateInName("Meeting_2026-10-07_11.18.17", timeZone: TimeZone(identifier: "Europe/Madrid")!)
        XCTAssertEqual(madrid, utcDate?.addingTimeInterval(-2 * 3600))
    }

    func testDateInNameAcceptsDateOnlyAndRejectsNonsense() {
        XCTAssertNotNil(NotesLibrary.dateInName("2026-10-05_Event_Title", timeZone: utc))
        XCTAssertNil(NotesLibrary.dateInName("Test_roadmap", timeZone: utc))
        XCTAssertNil(NotesLibrary.dateInName("x_2026-13-40", timeZone: utc))
    }

    // MARK: Availability (the disabled reasons the window prints)

    func testNoteWithEverythingAllowsAllButCompareAndClips() throws {
        let (notes, work) = try library()
        let e = try entry("Meeting_2026-10-07_11.18.17", in: NotesLibrary.scan(notesDir: notes, workDir: work, timeZone: utc))
        for action in NoteAction.allCases where action != .compare && action != .exportClips {
            XCTAssertEqual(NotesLibrary.availability(action, for: e), .available, "\(action)")
        }
        XCTAssertEqual(NotesLibrary.availability(.compare, for: e), .unavailable("only one version"))
        XCTAssertEqual(NotesLibrary.availability(.exportClips, for: e), .unavailable("no key moments marked"))
    }

    func testNoteWithoutTimestampsCannotExportAndSaysWhy() throws {
        // 2943.1: the reason is visible on the note, not hidden behind a greyed menu item.
        let (notes, work) = try library()
        let e = try entry("Meeting_2026-10-05_10.39.49", in: NotesLibrary.scan(notesDir: notes, workDir: work, timeZone: utc))
        XCTAssertEqual(NotesLibrary.availability(.exportTranscript, for: e), .unavailable("no timestamps saved"))
        XCTAssertEqual(NotesLibrary.availability(.regenerate, for: e), .available)
        XCTAssertEqual(NotesLibrary.availability(.copyTranscript, for: e), .available)
        XCTAssertEqual(NotesLibrary.marks(e), ["no timestamps"])
    }

    func testNoteWithoutSavedTranscriptCannotRegenerateAndSaysWhy() throws {
        // 2947.7: deleting <base>.transcript.clean.txt shows up as a disabled action with a reason.
        let (notes, work) = try library()
        let transcript = work.appendingPathComponent("Meeting_2026-10-05_10.39.49.transcript.clean.txt")
        try FileManager.default.removeItem(at: transcript)
        let e = try entry("Meeting_2026-10-05_10.39.49", in: NotesLibrary.scan(notesDir: notes, workDir: work, timeZone: utc))
        for action in [NoteAction.regenerate, .copyTranscript, .openTranscript, .exportTranscript] {
            XCTAssertEqual(NotesLibrary.availability(action, for: e), .unavailable("no saved transcript"), "\(action)")
        }
        XCTAssertEqual(NotesLibrary.availability(.open, for: e), .available)
        XCTAssertEqual(NotesLibrary.availability(.ask, for: e), .available)
        XCTAssertEqual(NotesLibrary.marks(e), ["no transcript"])
    }

    func testPendingRegenerateBlocksTheActionsThatRewriteTheNote() throws {
        let (notes, work) = try library()
        let e = try entry("Meeting_2026-10-07_11.18.17", in: NotesLibrary.scan(notesDir: notes, workDir: work, timeZone: utc))
        XCTAssertEqual(NotesLibrary.availability(.regenerate, for: e, busy: .waiting), .unavailable("already waiting to regenerate"))
        XCTAssertEqual(NotesLibrary.availability(.regenerate, for: e, busy: .running), .unavailable("regenerating now"))
        XCTAssertEqual(NotesLibrary.availability(.renameSpeakers, for: e, busy: .waiting), .unavailable("wait for the regenerate to finish"))
        XCTAssertEqual(NotesLibrary.availability(.exportTranscript, for: e, busy: .running), .available)
        XCTAssertEqual(NotesLibrary.marks(e, busy: .waiting).first, "regenerate waiting")
    }

    func testRenameNeedsSpeakersAndKeyMomentsEnableClips() throws {
        let (notes, work) = try library()
        var e = try entry("Roadmap_2026-08-12", in: NotesLibrary.scan(notesDir: notes, workDir: work, timeZone: utc))
        XCTAssertEqual(NotesLibrary.availability(.renameSpeakers, for: e), .unavailable("no speakers found"))
        e.keyMoments = 3
        XCTAssertEqual(NotesLibrary.availability(.exportClips, for: e), .available)
    }

    // MARK: Staying current

    func testNewNoteAppearsOnTheNextScanAndSelectionStays() throws {
        // 2947.9: a note written while the window is open is listed, and the selection does not move to it.
        let (notes, work) = try library()
        let cache = NotesLibraryCache()
        let before = NotesLibrary.scan(notesDir: notes, workDir: work, cache: cache, timeZone: utc)
        let selection = ["Meeting_2026-10-05_10.39.49"]
        write(notes.appendingPathComponent("Meeting_2026-10-07_11.26.54.md"), "# Meeting notes\n")
        let after = NotesLibrary.scan(notesDir: notes, workDir: work, cache: cache, timeZone: utc)
        XCTAssertEqual(after.count, before.count + 1)
        XCTAssertEqual(after.first?.base, "Meeting_2026-10-07_11.26.54")
        XCTAssertEqual(NotesLibrary.retainedSelection(selection, in: after), selection)
    }

    func testSelectionDropsANoteThatWasDeleted() throws {
        let (notes, work) = try library()
        try FileManager.default.removeItem(at: notes.appendingPathComponent("Roadmap_2026-08-12.md"))
        let entries = NotesLibrary.scan(notesDir: notes, workDir: work, timeZone: utc)
        XCTAssertEqual(NotesLibrary.retainedSelection(["Roadmap_2026-08-12", "Meeting_2026-10-05_10.39.49"], in: entries),
                       ["Meeting_2026-10-05_10.39.49"])
    }

    func testCachedRowIsRefreshedWhenASidecarAppearsOrGoes() throws {
        let (notes, work) = try library()
        let cache = NotesLibraryCache()
        let base = "Meeting_2026-10-05_10.39.49"
        XCTAssertFalse(try entry(base, in: NotesLibrary.scan(notesDir: notes, workDir: work, cache: cache, timeZone: utc)).hasSegments)
        try segments().save(workDir: work, base: base)
        XCTAssertTrue(try entry(base, in: NotesLibrary.scan(notesDir: notes, workDir: work, cache: cache, timeZone: utc)).hasSegments)
        try FileManager.default.removeItem(at: Pipeline.cachedTranscriptURL(workDir: work, base: base))
        XCTAssertFalse(try entry(base, in: NotesLibrary.scan(notesDir: notes, workDir: work, cache: cache, timeZone: utc)).hasCleanTranscript)
    }

    func testCachedScanEqualsUncachedScan() throws {
        let (notes, work) = try library()
        let cache = NotesLibraryCache()
        _ = NotesLibrary.scan(notesDir: notes, workDir: work, cache: cache, timeZone: utc)
        XCTAssertEqual(NotesLibrary.scan(notesDir: notes, workDir: work, cache: cache, timeZone: utc),
                       NotesLibrary.scan(notesDir: notes, workDir: work, timeZone: utc))
    }

    // MARK: Filter and labels

    func testFilterMatchesTitleAndFileNameIgnoringCaseAndAccents() throws {
        let (notes, work) = try library()
        write(notes.appendingPathComponent("Reunio_equip.md"), "# Reunió d'equip\n")
        let entries = NotesLibrary.scan(notesDir: notes, workDir: work, timeZone: utc)
        XCTAssertEqual(NotesLibrary.filter(entries, query: "").count, entries.count)
        XCTAssertEqual(NotesLibrary.filter(entries, query: "ROADMAP").map(\.base), ["Roadmap_2026-08-12"])
        XCTAssertEqual(NotesLibrary.filter(entries, query: "reunio equip").map(\.base), ["Reunio_equip"])
        XCTAssertEqual(NotesLibrary.filter(entries, query: "2026-10-05").map(\.base), ["Meeting_2026-10-05_10.39.49"])
        XCTAssertEqual(NotesLibrary.filter(entries, query: "nothing like this"), [])
    }

    func testLengthLabel() throws {
        let (notes, work) = try library()
        var e = try XCTUnwrap(NotesLibrary.scan(notesDir: notes, workDir: work, timeZone: utc).first)
        e.wordCount = 5310; e.durationSeconds = 42 * 60
        XCTAssertEqual(NotesLibrary.lengthLabel(e), "42 min · 5,310 words")
        e.durationSeconds = 95 * 60
        XCTAssertEqual(NotesLibrary.lengthLabel(e), "1 h 35 min · 5,310 words")
        e.durationSeconds = nil; e.wordCount = 1
        XCTAssertEqual(NotesLibrary.lengthLabel(e), "1 word")
    }

    // MARK: Exporting several transcripts

    func testBatchPlanNeverReusesAName() {
        let plan = TranscriptBatchExport.plan(bases: ["a", "b", "a"], format: .srt, existing: ["A.srt", "b.srt", "b 2.srt"])
        XCTAssertEqual(plan.map(\.fileName), ["a 2.srt", "b 3.srt", "a 3.srt"])
    }

    func testBatchExportWritesReadyNotesAndReportsTheRest() throws {
        let (notes, work) = try library()
        let entries = NotesLibrary.scan(notesDir: notes, workDir: work, timeZone: utc)
        let split = NotesLibrary.exportable(entries)
        XCTAssertEqual(split.ready.map(\.base), ["Meeting_2026-10-07_11.18.17"])
        XCTAssertEqual(split.skipped.count, 2)

        let folder = notes.deletingLastPathComponent().appendingPathComponent("out")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let existing = folder.appendingPathComponent("Meeting_2026-10-07_11.18.17.srt")
        write(existing, "keep me")
        let outcome = TranscriptBatchExport.run(bases: entries.map(\.base), format: .srt, workDir: work, folder: folder)
        XCTAssertEqual(outcome.written.map(\.lastPathComponent), ["Meeting_2026-10-07_11.18.17 2.srt"])
        XCTAssertEqual(outcome.failures.count, 2)
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "keep me", "an existing file is never overwritten")
        XCTAssertTrue(try String(contentsOf: outcome.written[0], encoding: .utf8).contains("hello there"))
    }
}
