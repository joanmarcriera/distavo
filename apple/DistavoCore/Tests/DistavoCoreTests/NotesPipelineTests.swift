import XCTest
@testable import DistavoCore

/// Vikunja #2954 end to end through `Pipeline.processOne` / `Pipeline.regenerate` with fakes:
/// byte-identical defaults, frontmatter + tags + tracked terms, idempotent regenerate,
/// and every existing reader coping with a note that has frontmatter.
final class NotesPipelineTests: XCTestCase {

    private final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var _contexts: [NoteContext] = []
        func add(_ c: NoteContext) { lock.lock(); _contexts.append(c); lock.unlock() }
        var contexts: [NoteContext] { lock.lock(); defer { lock.unlock() }; return _contexts }
    }

    private let recordingName = "Meeting 2026-10-05 10.00.00.opus"

    private func env(_ tweak: (inout Config) -> Void = { _ in }) throws -> (Config, URL, URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("distavo-notes-\(UUID().uuidString)")
        let rec = root.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: rec, withIntermediateDirectories: true)
        let input = rec.appendingPathComponent(recordingName)
        try Data([0, 1, 2, 3]).write(to: input)
        var cfg = Config()
        cfg.recordingsDir = rec.path
        cfg.notesDir = root.appendingPathComponent("notes").path
        cfg.workDir = root.appendingPathComponent("work").path
        tweak(&cfg)
        return (cfg, input, URL(fileURLWithPath: cfg.notesDir), URL(fileURLWithPath: cfg.workDir))
    }

    private let transcribeResult: [String: Any] = [
        "engine": "Test engine",
        "detections": [["code": "ca", "probability": 0.9]],
        "segments": [
            ["speaker": "SPEAKER_00", "text": "Hello everyone.", "start": 0.0, "end": 4.0],
            ["speaker": "SPEAKER_01", "text": "We moved the Slurm cluster to the new rack.", "start": 192.0, "end": 200.0],
            ["speaker": "SPEAKER_00", "text": "Fine.", "start": 4190.0, "end": 4200.0],
        ],
    ]

    private func deps(_ seen: Seen, summary: String = PipelineTests.validNote,
                      transcribe: [String: Any]? = nil) -> PipelineDeps {
        let result = transcribe ?? transcribeResult
        return PipelineDeps(
            convertToWav: { _, dest in
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data([0]).write(to: dest)
            },
            transcribe: { _, _ in result },
            ollamaReachable: { _ in true },
            summarise: { _, _, _, ctx in seen.add(ctx); return summary },
            audioDurationSeconds: { _ in nil })
    }

    private func run(_ cfg: Config, _ input: URL, _ d: PipelineDeps) async -> ProcessResult {
        await Pipeline.processOne(path: input, config: cfg, deps: d, stableChecks: 1, stableDelay: 0)
    }

    private func read(_ url: URL?) -> String { url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "" }

    // MARK: byte-identical defaults

    func testDefaultsWriteExactlyTheOldNoteAndPrompt() async throws {
        let (cfg, input, _, _) = try env()
        let seen = Seen()
        let r = await run(cfg, input, deps(seen))
        XCTAssertEqual(r.status, .done, r.message)
        let footer = Pipeline.provenanceFooter(from: transcribeResult)
        XCTAssertFalse(footer.isEmpty)
        XCTAssertEqual(read(r.notePath), PipelineTests.validNote + footer)
        XCTAssertNil(seen.contexts[0].customInstruction)
        XCTAssertEqual(seen.contexts[0].prompt(transcript: "t"),
                       NoteContext(noteOwner: cfg.noteOwner, userSpeaker: cfg.userSpeaker, participants: nil,
                                   meetingDate: seen.contexts[0].meetingDate, promptStyle: cfg.summarise.promptStyle,
                                   noteLanguage: seen.contexts[0].noteLanguage, glossary: [], template: nil).prompt(transcript: "t"))
    }

    func testTrackedTermsAloneChangeOnlyTheNoteNotThePrompt() async throws {
        let (cfg, input, _, _) = try env { $0.notes.trackedTerms = ["Slurm"] }
        let seen = Seen()
        let r = await run(cfg, input, deps(seen))
        XCTAssertNil(seen.contexts[0].customInstruction)
        let note = read(r.notePath)
        XCTAssertFalse(note.hasPrefix("---"), "frontmatter is its own switch")
        XCTAssertTrue(note.contains("## Tracked terms"))
    }

    // MARK: frontmatter, tags, tracked terms

    func testFrontmatterTagsTrackedTermsAndAutoTitle() async throws {
        let (cfg, input, notes, work) = try env {
            $0.notes = NotesConfig(frontmatter: true, autoTitle: true, autoTags: true, trackedTerms: ["Slurm", "GDPR"])
        }
        let base = DistavoState.baseFor(recordingsDir: URL(fileURLWithPath: cfg.recordingsDir), path: input)
        try SpeakerHints(count: 2, participants: "Edward (Cambridge) — interviewer; Marc (me)").save(workDir: work, base: base)
        let seen = Seen()
        let summary = PipelineTests.validNote + "\n\nDistavo-Title: Cluster move: Q4\nDistavo-Tags: Budget, hiring plan\n"
        let r = await run(cfg, input, deps(seen, summary: summary))
        XCTAssertEqual(r.status, .done, r.message)
        let note = read(r.notePath)

        XCTAssertTrue(note.hasPrefix("---\ndate: 2026-10-05\n"), note)
        let title = NoteFrontmatter.value("title", in: note)
        XCTAssertEqual(title, "Cluster move - Q4")
        XCTAssertEqual(NoteFrontmatter.value("source", in: note), recordingName)
        XCTAssertTrue(note.contains("attendees: [Edward (Cambridge), Marc (me)]"), note)
        XCTAssertTrue(note.contains("duration_minutes: 70\n"))
        let tagLine = try XCTUnwrap(note.components(separatedBy: "\n").first { $0.hasPrefix("tags:") })
        XCTAssertEqual(tagLine, "tags: [meeting, lang/ca, slurm, budget, hiring-plan]")   // GDPR never occurred: no tag

        // Tracked term: timestamped line, before the provenance footer, after the notes.
        XCTAssertTrue(note.contains("- [03:12] **Slurm** — \"We moved the Slurm cluster to the new rack.\" (SPEAKER_01)"), note)
        XCTAssertFalse(note.contains("GDPR"))
        let tracked = try XCTUnwrap(note.range(of: "## Tracked terms")), footer = try XCTUnwrap(note.range(of: "_Transcribed on this Mac"))
        XCTAssertLessThan(tracked.lowerBound, footer.lowerBound)
        XCTAssertFalse(note.contains("Distavo-Title"), "machine-readable lines never reach the note")
        XCTAssertFalse(note.contains("Distavo-Tags"))

        // The note keeps its base name (markers/sidecars key on it); the title is only metadata.
        XCTAssertEqual(r.notePath?.lastPathComponent, "\(base).md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: notes.appendingPathComponent("\(base).md").path))
        // The prompt carried the request.
        XCTAssertTrue(seen.contexts[0].customInstruction?.contains("Distavo-Title:") == true)
    }

    func testModelThatIgnoresTheRequestNeverFailsTheRecording() async throws {
        let (cfg, input, _, _) = try env { $0.notes = NotesConfig(frontmatter: true, autoTitle: true, autoTags: true) }
        let r = await run(cfg, input, deps(Seen()))
        XCTAssertEqual(r.status, .done, r.message)
        let note = read(r.notePath)
        XCTAssertNil(NoteFrontmatter.value("title", in: note))
        XCTAssertTrue(note.contains("tags: [meeting, lang/ca]"))
    }

    func testTextOnlyResultListsTrackedTermsWithoutTimestamps() async throws {
        let (cfg, input, _, _) = try env { $0.notes = NotesConfig(trackedTerms: ["slurm"]) }
        let untimed: [String: Any] = ["segments": [["speaker": "SPEAKER_00", "text": "We run Slurm daily."]]]
        let r = await run(cfg, input, deps(Seen(), transcribe: untimed))
        let note = read(r.notePath)
        XCTAssertTrue(note.contains("- **slurm** — \"We run Slurm daily.\" (SPEAKER_00)"), note)
    }

    // MARK: readers cope with frontmatter

    func testExistingReadersStillWorkOnANoteWithFrontmatter() async throws {
        let (cfg, input, notes, _) = try env { $0.notes = NotesConfig(frontmatter: true, trackedTerms: ["Slurm"]) }
        let r = await run(cfg, input, deps(Seen()))
        let note = read(r.notePath)
        XCTAssertTrue(note.hasPrefix("---\n"))
        // newestNote lists it like any other note.
        XCTAssertEqual(DistavoState.newestNote(inNotesDir: notes)?.lastPathComponent, r.notePath?.lastPathComponent)
        // The body (what viewers show) starts with the title heading again.
        XCTAssertTrue(NoteFrontmatter.strip(note).hasPrefix("# Meeting notes"))
        // The validator is happy with the whole note and with the stripped body.
        XCTAssertEqual(SummaryValidator.validate(note), [])
        XCTAssertEqual(SummaryValidator.validate(NoteFrontmatter.strip(note)), [])
        // The footer carry-over used by regenerate still finds the footer.
        let footer = try XCTUnwrap(Pipeline.provenanceFooter(in: note))
        XCTAssertEqual(footer, Pipeline.provenanceFooter(from: transcribeResult))
        // Variant listing ignores nothing it should see.
        XCTAssertFalse(NoteVersions.isBackupName(r.notePath!.lastPathComponent))
    }

    // MARK: regenerate

    private func regenEnv(note: String) throws -> (Config, URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("distavo-notes-regen-\(UUID().uuidString)")
        var cfg = Config()
        cfg.recordingsDir = root.appendingPathComponent("recordings").path
        cfg.notesDir = root.appendingPathComponent("notes").path
        cfg.workDir = root.appendingPathComponent("work").path
        let notes = URL(fileURLWithPath: cfg.notesDir), work = URL(fileURLWithPath: cfg.workDir)
        for d in [notes, work] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        try "[SPEAKER_01]\nWe moved the Slurm cluster.".write(
            to: Pipeline.cachedTranscriptURL(workDir: work, base: "demo"), atomically: true, encoding: .utf8)
        try note.write(to: notes.appendingPathComponent("demo.md"), atomically: true, encoding: .utf8)
        return (cfg, notes, work)
    }

    func testRegenerateIsIdempotentKeepsFooterAndUserKeys() async throws {
        let footer = Pipeline.provenanceFooter(from: transcribeResult)
        let old = "---\ndate: 2026-10-05\nsource: rec.wav\nstatus: draft\ntags: [old]\n---\n# Meeting notes\nOLD" + footer
        var (cfg, notes, work) = try regenEnv(note: old)
        cfg.notes = NotesConfig(frontmatter: true, autoTitle: true, trackedTerms: ["Slurm"])
        try TranscriptSegments(segments: [.init(start: 61, end: 70, text: "We moved the Slurm cluster.", speaker: "SPEAKER_01")])
            .save(workDir: work, base: "demo")
        let d = deps(Seen(), summary: PipelineTests.validNote + "\nDistavo-Title: Regenerated\n")

        let first = await Pipeline.regenerate(base: "demo", options: .init(), config: cfg, deps: d)
        XCTAssertEqual(first.status, .done, first.message)
        let n1 = read(notes.appendingPathComponent("demo.md"))
        let second = await Pipeline.regenerate(base: "demo", options: .init(), config: cfg, deps: d)
        XCTAssertEqual(second.status, .done, second.message)
        let n2 = read(notes.appendingPathComponent("demo.md"))

        XCTAssertEqual(n1, n2, "regenerating twice yields the same note")
        XCTAssertNil(NoteFrontmatter.split(NoteFrontmatter.strip(n2)).block, "exactly one frontmatter block")
        XCTAssertEqual(n2.components(separatedBy: "\ntags:").count, 2)
        XCTAssertEqual(n2.components(separatedBy: "status: draft").count, 2, "user key preserved once")
        XCTAssertEqual(NoteFrontmatter.value("source", in: n2), "rec.wav", "source carried over when no recording path is given")
        XCTAssertEqual(NoteFrontmatter.value("date", in: n2), "2026-10-05")
        XCTAssertEqual(NoteFrontmatter.value("title", in: n2), "Regenerated")
        XCTAssertFalse(n2.contains("tags: [old]"))
        XCTAssertTrue(n2.contains("- [01:01] **Slurm**"), n2)
        XCTAssertTrue(n2.hasSuffix(footer), "provenance footer carried over, still last")
        XCTAssertFalse(n2.contains("Distavo-Title"))
    }

    func testRegenerateWithDefaultsStaysByteIdentical() async throws {
        let footer = Pipeline.provenanceFooter(from: transcribeResult)
        let (cfg, notes, _) = try regenEnv(note: "# Meeting notes\nOLD" + footer)
        let r = await Pipeline.regenerate(base: "demo", options: .init(), config: cfg, deps: deps(Seen()))
        XCTAssertEqual(r.status, .done, r.message)
        XCTAssertEqual(read(notes.appendingPathComponent("demo.md")), PipelineTests.validNote + footer)
    }
}
