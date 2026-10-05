// CalendarFrontmatterTests - calendar match x Obsidian output (Vikunja #2946 + #2954): the event title
// is the frontmatter title and the heading, calendar attendees are listed (YAML-quoted) in the
// frontmatter, the section order is untouched, and with the calendar feature off nothing changes.
import XCTest
@testable import DistavoCore

final class CalendarFrontmatterTests: XCTestCase {

    private func tmp() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("distavo-calfm-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    private func occurrences(_ s: String, _ sub: String) -> Int { s.components(separatedBy: sub).count - 1 }

    private func deps() -> PipelineDeps {
        PipelineDeps(
            convertToWav: { _, dest in try Data([0]).write(to: dest) },
            transcribe: { _, _ in ["segments": [["speaker": "SPEAKER_00", "text": "We moved the Slurm cluster.", "start": 192.0, "end": 200.0]]] },
            ollamaReachable: { _ in true },
            summarise: { _, _, _, _ in PipelineTests.validNote },
            audioDurationSeconds: { _ in nil })
    }

    private struct Env { var cfg: Config; var input: URL; var work: URL; var notes: URL; var base: String }

    private func env(calendarEnabled: Bool, withMatch: Bool, vault: URL? = nil) throws -> Env {
        let root = tmp()
        let rec = root.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: rec, withIntermediateDirectories: true)
        let input = rec.appendingPathComponent("Meeting 2026-10-05 10.00.00.wav")
        try Data([0, 1, 2, 3]).write(to: input)
        var cfg = Config()
        cfg.recordingsDir = rec.path; cfg.notesDir = root.appendingPathComponent("notes").path
        cfg.workDir = root.appendingPathComponent("work").path
        cfg.notes = NotesConfig(frontmatter: true, trackedTerms: ["Slurm"], vaultDir: vault?.path ?? "")
        cfg.calendar = CalendarConfig(enabled: calendarEnabled)
        let work = URL(fileURLWithPath: cfg.workDir)
        let base = DistavoState.baseFor(recordingsDir: rec, path: input)
        try ScratchpadNotes(lines: [.init(offsetSeconds: 30, text: "check the pricing sheet")]).save(workDir: work, base: base)
        try RecordingBookmarks(marks: [.init(offsetSeconds: 192, label: "the move")]).save(workDir: work, base: base)
        if withMatch {
            let start = Pipeline.meetingDate(for: input)!
            // Attendees NOT confirmed by the owner: they must still reach the frontmatter (data, not prompt).
            try CalendarMatchStore.save(CalendarMatch(title: "Q3 review: \"Board\" #1", start: start, end: start.addingTimeInterval(3600),
                                                      attendees: ["Ada Lovelace", "Grace Hopper"], recordingStart: start),
                                        workDir: work, base: base)
        }
        return Env(cfg: cfg, input: input, work: work, notes: URL(fileURLWithPath: cfg.notesDir), base: base)
    }

    func testMatchSetsFrontmatterTitleHeadingAttendeesAndKeepsSectionOrder() async throws {
        let e = try env(calendarEnabled: true, withMatch: true)
        let r = await Pipeline.processOne(path: e.input, config: e.cfg, deps: deps(), stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(r.status, .done, r.message)
        let note = try String(contentsOf: r.notePath!, encoding: .utf8)
        let split = NoteFrontmatter.split(note)
        let block = try XCTUnwrap(split.block)
        XCTAssertTrue(block.contains("title: "), block)
        XCTAssertTrue(block.contains("Q3 review"), block)
        XCTAssertTrue(block.contains("Ada Lovelace") && block.contains("Grace Hopper"), "calendar attendees in the frontmatter")
        // The heading was rewritten in the BODY; frontmatter is not mistaken for it.
        XCTAssertTrue(split.body.hasPrefix("# Q3 review: \"Board\" #1\n"), split.body)
        XCTAssertFalse(note.contains("# Meeting notes"))
        // Fixed order: frontmatter, summary (Highlights), Key moments, Tracked terms, footer; each once.
        var last = note.startIndex
        for m in ["\n---\n# Q3 review", "## Highlights", "## Key moments", "## Tracked terms"] {
            guard let rg = note.range(of: m, range: last..<note.endIndex) else { XCTFail("\(m) missing or out of order\n\(note)"); return }
            last = rg.upperBound
        }
        for m in ["## Highlights", "## Key moments", "## Tracked terms"] { XCTAssertEqual(occurrences(note, m), 1, m) }
    }

    func testRegenerateKeepsTitleAttendeesAndOrder() async throws {
        let e = try env(calendarEnabled: true, withMatch: true)
        let first = await Pipeline.processOne(path: e.input, config: e.cfg, deps: deps(), stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(first.status, .done, first.message)
        let r = await Pipeline.regenerate(base: e.base, options: .init(), config: e.cfg, deps: deps())
        XCTAssertEqual(r.status, .done, r.message)
        let note = try String(contentsOf: e.notes.appendingPathComponent("\(e.base).md"), encoding: .utf8)
        let split = NoteFrontmatter.split(note)
        XCTAssertTrue(split.block?.contains("Ada Lovelace") ?? false)
        XCTAssertTrue(split.body.hasPrefix("# Q3 review"))
        for m in ["## Highlights", "## Key moments", "## Tracked terms"] { XCTAssertEqual(occurrences(note, m), 1, m) }
    }

    func testCalendarOffIsByteIdenticalToNoMatch() async throws {
        let off = try env(calendarEnabled: false, withMatch: true)      // sidecar present but feature off
        let none = try env(calendarEnabled: false, withMatch: false)
        let a = await Pipeline.processOne(path: off.input, config: off.cfg, deps: deps(), stableChecks: 1, stableDelay: 0)
        let b = await Pipeline.processOne(path: none.input, config: none.cfg, deps: deps(), stableChecks: 1, stableDelay: 0)
        let na = try String(contentsOf: a.notePath!, encoding: .utf8), nb = try String(contentsOf: b.notePath!, encoding: .utf8)
        XCTAssertEqual(na, nb)
        XCTAssertTrue(na.contains("# Meeting notes"))
        XCTAssertFalse(na.contains("Ada Lovelace"))
    }

    func testVaultCopyIsNamedAfterTheEventThroughVaultExportSanitiser() async throws {
        let vault = tmp()
        let e = try env(calendarEnabled: true, withMatch: true, vault: vault)
        let r = await Pipeline.processOne(path: e.input, config: e.cfg, deps: deps(), stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(r.status, .done, r.message)
        XCTAssertEqual(NoteMeta.loadTitle(workDir: e.work, base: e.base), "Q3 review - \"Board\" #1", "the stored title already went through NoteMeta's own sanitiser")
    }
}
