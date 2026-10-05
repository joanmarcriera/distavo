import XCTest
@testable import DistavoCore

/// Vikunja #2954 review fixes: fixed note order with Highlights / Key moments, vault inside scanned
/// folders, title without frontmatter, strict fence, speaker rename on frontmatter notes,
/// byte-limited vault names, ActionItems titles.
final class NotesReviewFixTests: XCTestCase {

    private func tmp(_ name: String) -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("distavo-\(name)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    // MARK: 1. note order

    private let result: [String: Any] = [
        "engine": "Test engine",
        "segments": [
            ["speaker": "SPEAKER_00", "text": "Hello everyone.", "start": 0.0, "end": 4.0],
            ["speaker": "SPEAKER_01", "text": "We moved the Slurm cluster to the new rack.", "start": 192.0, "end": 200.0],
        ],
    ]

    private func fakeDeps(_ summary: String = PipelineTests.validNote) -> PipelineDeps {
        PipelineDeps(
            convertToWav: { _, dest in
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data([0]).write(to: dest)
            },
            transcribe: { _, _ in self.result },
            ollamaReachable: { _ in true },
            summarise: { _, _, _, _ in summary },
            audioDurationSeconds: { _ in nil })
    }

    private func occurrences(_ s: String, _ needle: String) -> Int { s.components(separatedBy: needle).count - 1 }

    func testProcessOneFixedOrderWithEveryExtraSectionAndByteIdenticalWhenOff() async throws {
        let root = tmp("order")
        let rec = root.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: rec, withIntermediateDirectories: true)
        let input = rec.appendingPathComponent("Meeting 2026-10-05 10.00.00.opus")
        try Data([0, 1, 2, 3]).write(to: input)
        var cfg = Config()
        cfg.recordingsDir = rec.path; cfg.notesDir = root.appendingPathComponent("notes").path
        cfg.workDir = root.appendingPathComponent("work").path
        let work = URL(fileURLWithPath: cfg.workDir)
        let base = DistavoState.baseFor(recordingsDir: rec, path: input)
        try ScratchpadNotes(lines: [.init(offsetSeconds: 30, text: "check the pricing sheet")]).save(workDir: work, base: base)
        try RecordingBookmarks(marks: [.init(offsetSeconds: 192, label: "the move")]).save(workDir: work, base: base)

        // Everything off: the note main would write.
        let off = await Pipeline.processOne(path: input, config: cfg, deps: fakeDeps(), stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(off.status, .done, off.message)
        let plain = try String(contentsOf: off.notePath!, encoding: .utf8)
        XCTAssertEqual(occurrences(plain, "## Highlights"), 1, plain)
        XCTAssertEqual(occurrences(plain, "## Key moments"), 1, plain)
        XCTAssertTrue(plain.hasSuffix(Pipeline.provenanceFooter(from: result)))

        // Everything on (fresh state dir so it re-runs).
        try FileManager.default.removeItem(at: work.appendingPathComponent(".state"))
        try FileManager.default.removeItem(at: off.notePath!)
        cfg.notes = NotesConfig(frontmatter: true, trackedTerms: ["Slurm"])
        let on = await Pipeline.processOne(path: input, config: cfg, deps: fakeDeps(), stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(on.status, .done, on.message)
        let note = try String(contentsOf: on.notePath!, encoding: .utf8)
        assertOrder(note)
        // Stripping what #2954 adds yields exactly the all-off note.
        let stripped = NoteFrontmatter.strip(note)
        let trackedRange = try XCTUnwrap(stripped.range(of: "\n## Tracked terms"))
        let mark = "\n\n---\n_Transcribed"
        let footerRange = try XCTUnwrap(stripped.range(of: mark))
        let plainFooter = try XCTUnwrap(plain.range(of: mark))
        XCTAssertEqual(String(stripped[..<trackedRange.lowerBound]), String(plain[..<plainFooter.lowerBound]))
        XCTAssertEqual(String(stripped[footerRange.lowerBound...]), String(plain[plainFooter.lowerBound...]))
    }

    private func assertOrder(_ note: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(note.hasPrefix("---\n"), "frontmatter first", file: file, line: line)
        var last = note.startIndex
        for m in ["\n---\n# Meeting notes", "## Highlights", "## Key moments", "## Tracked terms", "_Transcribed on this Mac"] {
            guard let r = note.range(of: m, range: last..<note.endIndex) else { XCTFail("\(m) missing or out of order", file: file, line: line); return }
            last = r.upperBound
        }
        for m in ["## Highlights", "## Key moments", "## Tracked terms"] {
            XCTAssertEqual(occurrences(note, m), 1, "\(m) must appear exactly once", file: file, line: line)
        }
    }

    func testRegenerateKeepsEverySectionOnceInOrder() async throws {
        let root = tmp("regen-order")
        var cfg = Config()
        cfg.recordingsDir = root.appendingPathComponent("recordings").path
        cfg.notesDir = root.appendingPathComponent("notes").path
        cfg.workDir = root.appendingPathComponent("work").path
        let notes = URL(fileURLWithPath: cfg.notesDir), work = URL(fileURLWithPath: cfg.workDir)
        for d in [notes, work] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        let footer = Pipeline.provenanceFooter(from: result)
        try "[SPEAKER_01]\nWe moved the Slurm cluster.".write(
            to: Pipeline.cachedTranscriptURL(workDir: work, base: "demo"), atomically: true, encoding: .utf8)
        try ("# Meeting notes\nOLD" + footer).write(to: notes.appendingPathComponent("demo.md"), atomically: true, encoding: .utf8)
        try TranscriptSegments(segments: [.init(start: 192, end: 200, text: "We moved the Slurm cluster.", speaker: "SPEAKER_01")]).save(workDir: work, base: "demo")
        try ScratchpadNotes(lines: [.init(offsetSeconds: 30, text: "check the pricing sheet")]).save(workDir: work, base: "demo")
        try RecordingBookmarks(marks: [.init(offsetSeconds: 192, label: "the move")]).save(workDir: work, base: "demo")

        let off = await Pipeline.regenerate(base: "demo", options: .init(), config: cfg, deps: fakeDeps())
        XCTAssertEqual(off.status, .done, off.message)
        let plain = try String(contentsOf: notes.appendingPathComponent("demo.md"), encoding: .utf8)
        XCTAssertEqual(occurrences(plain, "## Highlights"), 1); XCTAssertEqual(occurrences(plain, "## Key moments"), 1)

        cfg.notes = NotesConfig(frontmatter: true, trackedTerms: ["Slurm"])
        for _ in 0..<2 {   // twice: still once each
            let on = await Pipeline.regenerate(base: "demo", options: .init(), config: cfg, deps: fakeDeps())
            XCTAssertEqual(on.status, .done, on.message)
        }
        let note = try String(contentsOf: notes.appendingPathComponent("demo.md"), encoding: .utf8)
        assertOrder(note)
        XCTAssertTrue(note.hasSuffix(footer))
    }

    // MARK: 2. vault inside scanned folders

    func testConflictDetection() throws {
        let root = tmp("conflict")
        let notes = root.appendingPathComponent("notes"), rec = root.appendingPathComponent("rec"), work = root.appendingPathComponent("work")
        for d in [notes, rec, work, root.appendingPathComponent("vault")] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        XCTAssertNotNil(VaultExport.conflict(vault: notes, avoiding: [notes]))
        XCTAssertNotNil(VaultExport.conflict(vault: notes.appendingPathComponent("Obsidian"), avoiding: [notes]))
        XCTAssertNotNil(VaultExport.conflict(vault: notes.appendingPathComponent("a/../Obsidian"), avoiding: [notes]))
        XCTAssertNil(VaultExport.conflict(vault: root.appendingPathComponent("vault"), avoiding: [notes, rec, work]))
        XCTAssertNil(VaultExport.conflict(vault: root.appendingPathComponent("notes-vault"), avoiding: [notes]), "a sibling with the same prefix is fine")
        XCTAssertNil(VaultExport.conflict(vault: root, avoiding: [notes]), "a parent of the notes folder is fine")
        // A symlink into the notes folder is resolved.
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: notes)
        XCTAssertNotNil(VaultExport.conflict(vault: link, avoiding: [notes]))
        XCTAssertNotNil(VaultExport.conflict(vaultDir: notes.path, notesDir: notes.path, recordingsDir: rec.path, workDir: work.path))
        XCTAssertNil(VaultExport.conflict(vaultDir: "", notesDir: notes.path, recordingsDir: rec.path, workDir: work.path))
    }

    func testExportSkipsAVaultInsideNotesRecordingsOrWork() throws {
        let root = tmp("conflict-export")
        let notes = root.appendingPathComponent("notes"), work = root.appendingPathComponent("work")
        for d in [notes, work, notes.appendingPathComponent("Obsidian")] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        let note = notes.appendingPathComponent("demo.md")
        try "# n".write(to: note, atomically: true, encoding: .utf8)
        for vault in [notes, notes.appendingPathComponent("Obsidian"), work] {
            let out = VaultExport.export(note: note, base: "demo", notes: NotesConfig(vaultDir: vault.path), workDir: work, avoiding: [notes])
            guard case .skipped(let why) = out else { return XCTFail("\(out)") }
            XCTAssertTrue(why.contains("outside"), why)
        }
        XCTAssertEqual((try FileManager.default.contentsOfDirectory(atPath: notes.appendingPathComponent("Obsidian").path)), [])
    }

    // MARK: 3. title without frontmatter

    func testTitleIsAskedOnlyWhenUsedAndNamesTheVaultCopyWithoutFrontmatter() async throws {
        // Asked only when it will be used.
        XCTAssertEqual(NoteMeta.requestText(NotesConfig(autoTitle: true)), "")
        XCTAssertEqual(NoteMeta.requestText(NotesConfig(autoTags: true)), "")
        XCTAssertTrue(NoteMeta.requestText(NotesConfig(autoTitle: true, vaultDir: "/v")).contains("Distavo-Title"))
        XCTAssertFalse(NoteMeta.requestText(NotesConfig(autoTitle: true, autoTags: true, vaultDir: "/v")).contains("Distavo-Tags"))
        XCTAssertTrue(NoteMeta.requestText(NotesConfig(frontmatter: true, autoTags: true)).contains("Distavo-Tags"))

        let root = tmp("title")
        let rec = root.appendingPathComponent("recordings"), vault = root.appendingPathComponent("vault")
        for d in [rec, vault] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        let input = rec.appendingPathComponent("Meeting 2026-10-05 10.00.00.opus")
        try Data([0, 1, 2, 3]).write(to: input)
        var cfg = Config()
        cfg.recordingsDir = rec.path; cfg.notesDir = root.appendingPathComponent("notes").path
        cfg.workDir = root.appendingPathComponent("work").path
        cfg.notes = NotesConfig(autoTitle: true, vaultDir: vault.path)   // frontmatter OFF
        let r = await Pipeline.processOne(path: input, config: cfg, deps: fakeDeps(PipelineTests.validNote + "\nDistavo-Title: Pricing review\n"), stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(r.status, .done, r.message)
        let work = URL(fileURLWithPath: cfg.workDir)
        let text = try String(contentsOf: r.notePath!, encoding: .utf8)
        XCTAssertFalse(text.hasPrefix("---")); XCTAssertFalse(text.contains("Distavo-Title"))
        let title = NoteMeta.loadTitle(workDir: work, base: r.base)
        XCTAssertEqual(title, "Pricing review")
        let out = VaultExport.export(note: r.notePath!, base: r.base, notes: cfg.notes, workDir: work, title: title)
        guard case .copied(let url) = out else { return XCTFail("\(out)") }
        XCTAssertTrue(url.lastPathComponent.hasSuffix("Pricing review.md"), url.lastPathComponent)
    }

    // MARK: 4. strict fence

    func testIndentedFenceInsideABlockScalarDoesNotCloseTheBlock() {
        let note = "---\ntitle: X\nnotes: |\n  text\n  ---\n  more text\nstatus: draft\n---\n# Meeting notes\nbody"
        let (block, body) = NoteFrontmatter.split(note)
        XCTAssertTrue(block?.contains("  more text") == true, "the block runs to the real fence")
        XCTAssertEqual(body, "# Meeting notes\nbody")
        // apply keeps the user's block scalar intact.
        let result = NoteFrontmatter.apply(NoteFrontmatterFields(title: "New"), to: note)
        XCTAssertTrue(result.contains("notes: |\n  text\n  ---\n  more text\n"), result)
        XCTAssertTrue(result.hasSuffix("---\n# Meeting notes\nbody"))
        // Trailing spaces / CR on a real fence are fine.
        XCTAssertNotNil(NoteFrontmatter.split("---  \r\ntitle: X\r\n---\t\r\nbody").block)
        // An indented line never opens one.
        XCTAssertNil(NoteFrontmatter.split(" ---\ntitle: X\n---\nbody").block)
    }

    // MARK: 5. speaker rename

    func testRenameRewritesOnlyTheBodyAndAttendeeEntries() {
        let note = "---\ndate: 2026-10-05\ntitle: Ann review\nattendees: [Ann, \"Bob (QA)\", Cy]\ntags: [meeting]\nsource: x.wav\n---\n# Meeting notes\n\nSPEAKER_00 agreed.\n"
        let out = SpeakerRename.rewriteNote(note, mapping: ["SPEAKER_00": "title", "Ann": "Anna", "Bob (QA)": "date"])
        XCTAssertTrue(out.hasPrefix("---\ndate: 2026-10-05\ntitle: Ann review\nattendees: [Anna, date, Cy]\ntags: [meeting]\nsource: x.wav\n---\n"), out)
        XCTAssertTrue(out.hasSuffix("title agreed.\n"), out)
        // Every other key line is byte-identical.
        let before = note.components(separatedBy: "\n"), after = out.components(separatedBy: "\n")
        XCTAssertEqual(before.count, after.count)
        for i in before.indices where !before[i].hasPrefix("attendees:") && !before[i].contains("SPEAKER_00") {
            XCTAssertEqual(before[i], after[i])
        }
        // A frontmatter-free note behaves as before.
        XCTAssertEqual(SpeakerRename.rewriteNote("SPEAKER_00 hi", mapping: ["SPEAKER_00": "Ann"]), "Ann hi")
    }

    func testRenameThroughApplyKeepsHashBookkeepingWithFrontmatter() throws {
        let root = tmp("rename")
        let notes = root.appendingPathComponent("notes"), work = root.appendingPathComponent("work")
        for d in [notes, work] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        let original = "---\ndate: 2026-10-05\nattendees: [SPEAKER_00]\ntags: [meeting]\n---\n# Meeting notes\n\nSPEAKER_00 agreed.\n"
        try original.write(to: notes.appendingPathComponent("demo.md"), atomically: true, encoding: .utf8)
        try "[SPEAKER_00]\nwe agree".write(to: work.appendingPathComponent("demo.transcript.clean.txt"), atomically: true, encoding: .utf8)
        let r = try SpeakerRename.apply(mapping: ["SPEAKER_00": "Ann"], base: "demo", notesDir: notes, workDir: work)
        XCTAssertFalse(r.changedFiles.isEmpty)
        let now = try String(contentsOf: notes.appendingPathComponent("demo.md"), encoding: .utf8)
        XCTAssertEqual(now, "---\ndate: 2026-10-05\nattendees: [Ann]\ntags: [meeting]\n---\n# Meeting notes\n\nAnn agreed.\n")
        let names = try XCTUnwrap(SpeakerNames.load(workDir: work, base: "demo"))
        XCTAssertEqual(names.originalNoteSHA256, SpeakerNames.sha256(Data(original.utf8)))
        XCTAssertEqual(names.lastNoteSHA256, SpeakerNames.sha256(Data(now.utf8)))
        // Speaker detection ignores the frontmatter.
        let found = SpeakerRename.detectSpeakers(note: original, transcript: nil, segments: nil).map(\.label)
        XCTAssertEqual(found, ["SPEAKER_00"])
    }

    // MARK: 6. byte-limited names

    func testVaultNamesAreCutByUTF8BytesWithoutSplittingCharacters() {
        for sample in ["会议".padding(toLength: 400, withPad: "会议", startingAt: 0),
                       String(repeating: "🚀", count: 300), String(repeating: "é", count: 500)] {
            let name = VaultExport.fileName(date: "2026-10-05", title: sample, base: "x")
            XCTAssertLessThanOrEqual(name.utf8.count, 255, "name must fit a file-system component")
            XCTAssertNotNil(String(data: Data(name.utf8), encoding: .utf8))
            XCTAssertTrue(name.hasSuffix(".md"))
        }
        XCTAssertEqual(VaultExport.utf8Prefix("ab🚀cd", maxBytes: 5), "ab")
        XCTAssertEqual(VaultExport.utf8Prefix("ab🚀cd", maxBytes: 6), "ab🚀")
        // It really writes.
        let dir = tmp("cjk")
        let name = VaultExport.fileName(date: "2026-10-05", title: String(repeating: "会", count: 300), base: "x")
        XCTAssertNoThrow(try "x".write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8))
    }

    // MARK: 7. ActionItems titles

    func testActionItemsTitlePrefersFrontmatterTitleAndIgnoresKeys() {
        let url = URL(fileURLWithPath: "/tmp/base.md")
        let with = Data("---\ndate: 2026-10-05\ntitle: Pricing review\n---\n# Meeting notes\n- [ ] x".utf8)
        XCTAssertEqual(ActionItems.noteTitle(data: with, url: url), "Pricing review")
        let without = Data("---\ndate: 2026-10-05\n---\n# Cluster move\n- [ ] x".utf8)
        XCTAssertEqual(ActionItems.noteTitle(data: without, url: url), "Cluster move")
        XCTAssertEqual(ActionItems.noteTitle(data: Data("---\ndate: 2026-10-05\n---\n# Meeting notes".utf8), url: url), "base")
    }
}
