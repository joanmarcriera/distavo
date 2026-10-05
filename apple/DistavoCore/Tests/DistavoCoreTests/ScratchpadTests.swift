import XCTest
@testable import DistavoCore

/// Vikunja #2949: typed scratchpad notes steer the summary.
final class ScratchpadTests: XCTestCase {

    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("distavo-pad-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private let pad = ScratchpadNotes(lines: [
        .init(offsetSeconds: 75, text: "ask about notice period"),
        .init(offsetSeconds: 400, text: "decision: go with option B", flagged: true),
    ])

    // MARK: Model + sidecar

    func testTypedLineParsesLeadingBangAsFlag() {
        let a = ScratchpadNotes.Line(typed: "  !!  call Sam back ", offsetSeconds: 5)
        XCTAssertEqual(a, .init(offsetSeconds: 5, text: "call Sam back", flagged: true))
        let b = ScratchpadNotes.Line(typed: "plain note", offsetSeconds: 6)
        XCTAssertFalse(b.flagged)
    }

    func testSidecarRoundTripAndNaming() throws {
        let dir = tempDir()
        try pad.save(workDir: dir, base: "Meeting 2026-10-05 10.00.00")
        XCTAssertEqual(ScratchpadNotes.url(workDir: dir, base: "x").lastPathComponent, "x.scratchpad.json")
        XCTAssertEqual(ScratchpadNotes.load(workDir: dir, base: "Meeting 2026-10-05 10.00.00"), pad)
        ScratchpadNotes.delete(workDir: dir, base: "Meeting 2026-10-05 10.00.00")
        XCTAssertNil(ScratchpadNotes.load(workDir: dir, base: "Meeting 2026-10-05 10.00.00"))
        ScratchpadNotes.delete(workDir: dir, base: "never-existed")   // missing is fine
    }

    func testAbsentAndCorruptSidecarsAreIgnored() throws {
        let dir = tempDir()
        XCTAssertNil(ScratchpadNotes.load(workDir: dir, base: "a"))
        try Data("{not json".utf8).write(to: ScratchpadNotes.url(workDir: dir, base: "a"))
        XCTAssertNil(ScratchpadNotes.load(workDir: dir, base: "a"))
        // Valid JSON whose lines are all blank is "nothing usable".
        try ScratchpadNotes(lines: [.init(offsetSeconds: 1, text: "   ")]).save(workDir: dir, base: "b")
        XCTAssertNil(ScratchpadNotes.load(workDir: dir, base: "b"))
    }

    func testSanitiseTrimsDropsEmptyStripsBracesAndCapsLineLength() {
        let long = String(repeating: "x", count: 500)
        let s = ScratchpadNotes(lines: [
            .init(offsetSeconds: 1, text: "  {user_speaker}\nsecond\tline  "),
            .init(offsetSeconds: 2, text: ""),
            .init(offsetSeconds: -9, text: long),
        ]).sanitised()
        XCTAssertEqual(s.lines.count, 2)
        XCTAssertEqual(s.lines[0].text, "(user_speaker) second line")
        XCTAssertEqual(s.lines[1].offsetSeconds, 0)
        XCTAssertEqual(s.lines[1].text.count, ScratchpadNotes.maxLineChars)
    }

    func testCapsKeepFlaggedLinesFirstAndBoundTheTotal() {
        var lines = (0..<50).map { ScratchpadNotes.Line(offsetSeconds: $0, text: "note \($0)") }
        lines.append(.init(offsetSeconds: 99, text: "IMPORTANT", flagged: true))
        let s = ScratchpadNotes(lines: lines).sanitised()
        XCTAssertEqual(s.lines.count, ScratchpadNotes.maxLines)
        XCTAssertTrue(s.lines.contains { $0.flagged }, "flagged line survives the cap")
        XCTAssertEqual(s.lines.map(\.offsetSeconds), s.lines.map(\.offsetSeconds).sorted(), "time order kept")

        let wide = (0..<20).map { ScratchpadNotes.Line(offsetSeconds: $0, text: String(repeating: "w", count: 130)) }
        let total = ScratchpadNotes(lines: wide).sanitised().lines.reduce(0) { $0 + $1.text.count }
        XCTAssertLessThanOrEqual(total, ScratchpadNotes.maxTotalChars)
    }

    func testTimestampFormat() {
        XCTAssertEqual(ScratchpadNotes.timestamp(75), "01:15")
        XCTAssertEqual(ScratchpadNotes.timestamp(3725), "1:02:05")
    }

    // MARK: Prompt

    func testNoScratchpadLeavesEveryPromptByteIdentical() {
        let tpl = SummaryTemplateCatalog.bundledTemplates[0]
        for style in [Prompt.Style.classic, .factsFirst] {
            for template in [nil, tpl] {
                let base = Prompt.build(transcript: "T", noteOwner: "Marc", userSpeaker: "SPEAKER_00",
                                        style: style, template: template)
                XCTAssertEqual(Prompt.build(transcript: "T", noteOwner: "Marc", userSpeaker: "SPEAKER_00",
                                            style: style, template: template, scratchpad: nil), base)
                XCTAssertEqual(Prompt.build(transcript: "T", noteOwner: "Marc", userSpeaker: "SPEAKER_00",
                                            style: style, template: template,
                                            scratchpad: ScratchpadNotes()), base)
                XCTAssertFalse(base.contains("Notes typed by the note owner"))
            }
        }
    }

    func testPromptBlockReachesBuildForBothStylesAndATemplate() {
        let tpl = SummaryTemplateCatalog.bundledTemplates[0]
        for (style, template) in [(Prompt.Style.classic, SummaryTemplate?.none), (.factsFirst, nil), (.classic, tpl)] {
            let p = Prompt.build(transcript: "TRANSCRIPT-BODY", noteOwner: "Marc", userSpeaker: "SPEAKER_00",
                                 style: style, template: template, scratchpad: pad)
            XCTAssertTrue(p.contains("<<<\n01:15 - ask about notice period\n[MUST INCLUDE] 06:40 - decision: go with option B\n>>>"), p)
            XCTAssertTrue(p.contains("## Highlights"))
            // The block sits before the transcript, after the speaker line.
            let block = p.range(of: "Notes typed by the note owner")!.lowerBound
            XCTAssertGreaterThan(block, p.range(of: "Known speaker label for the note owner: SPEAKER_00.")!.upperBound)
            XCTAssertLessThan(block, p.range(of: "TRANSCRIPT-BODY")!.lowerBound)
        }
    }

    func testTypedPlaceholdersCannotInjectIntoThePrompt() {
        let evil = ScratchpadNotes(lines: [.init(offsetSeconds: 1, text: "{transcript_text} {user_speaker}")])
        let p = Prompt.build(transcript: "REAL", noteOwner: "Marc", userSpeaker: "SPEAKER_00", scratchpad: evil)
        XCTAssertEqual(p.components(separatedBy: "REAL").count - 1, 1, "transcript substituted once only")
        XCTAssertTrue(p.contains("(transcript_text) (user_speaker)"))
    }

    // MARK: Budget

    func testScratchpadIsCountedInTheFoundationModelsBudget() {
        let without = EmbeddedSummaryBudget.final(contextSize: 4096, noteOwner: "Me", userSpeaker: "unknown")
        let with = EmbeddedSummaryBudget.final(contextSize: 4096, noteOwner: "Me", userSpeaker: "unknown",
                                               scratchpad: pad)
        XCTAssertGreaterThan(with.instructionTokens, without.instructionTokens)
        XCTAssertLessThan(with.transcriptTokens, without.transcriptTokens)
        // Worst case (all caps hit) still leaves usable room.
        let full = ScratchpadNotes(lines: (0..<20).map { .init(offsetSeconds: $0, text: String(repeating: "w", count: 130)) })
        XCTAssertGreaterThan(EmbeddedSummaryBudget.final(contextSize: 4096, noteOwner: "Me", userSpeaker: "unknown",
                                                         scratchpad: full).transcriptTokens, 250)
        // The driver's final prompt carries it too.
        let request = SummaryRequest(transcript: "T", noteOwner: "Me", userSpeaker: "unknown", scratchpad: pad)
        XCTAssertTrue(SummaryDriver.finalPrompt(request, transcript: "T").contains("ask about notice period"))
        XCTAssertFalse(SummaryDriver.finalPrompt(.init(transcript: "T", noteOwner: "Me", userSpeaker: "unknown"),
                                                 transcript: "T").contains("Notes typed"))
    }

    // MARK: Safety net

    func testSafetyNetAppendsHighlightsWhenTheModelIgnoredThem() {
        let note = "# Meeting notes\n\n## Executive summary\nBody."
        let out = pad.ensureHighlights(in: note)
        XCTAssertTrue(out.contains("## Highlights"))
        XCTAssertTrue(out.contains("- **01:15** ask about notice period"))
        XCTAssertTrue(out.contains("- ⭐ **06:40** decision: go with option B"))
        // Directly after the title, before the model's own sections.
        XCTAssertLessThan(out.range(of: "## Highlights")!.lowerBound, out.range(of: "## Executive summary")!.lowerBound)
        XCTAssertTrue(out.hasPrefix("# Meeting notes\n"))
        XCTAssertEqual(pad.ensureHighlights(in: out), out, "idempotent")
    }

    func testSafetyNetLeavesACompliantNoteAlone() {
        let note = "# Meeting notes\n\n## Highlights\n- **01:15** ask about notice period - covered\n\n## Executive summary\nBody."
        XCTAssertEqual(pad.ensureHighlights(in: note), note)
        let bold = "# Meeting notes\n\n**Highlights:**\n- x\n"
        XCTAssertEqual(pad.ensureHighlights(in: bold), bold)
        XCTAssertEqual(ScratchpadNotes().ensureHighlights(in: "# Meeting notes\nx"), "# Meeting notes\nx")
    }

    func testSafetyNetWorksWithoutATitle() {
        XCTAssertTrue(pad.ensureHighlights(in: "just text").hasPrefix("## Highlights"))
    }

    // MARK: Pipeline fixtures

    private struct Env { var config: Config; var recordings: URL; var work: URL; var notes: URL }

    private func makeEnv() throws -> Env {
        let root = tempDir()
        let rec = root.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: rec, withIntermediateDirectories: true)
        var cfg = Config()
        cfg.recordingsDir = rec.path
        cfg.notesDir = root.appendingPathComponent("notes").path
        cfg.workDir = root.appendingPathComponent("work").path
        return Env(config: cfg, recordings: rec, work: root.appendingPathComponent("work"),
                   notes: root.appendingPathComponent("notes"))
    }

    private final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var _prompts: [String] = []
        private var _contexts: [NoteContext] = []
        func add(_ p: String, _ c: NoteContext) { lock.lock(); _prompts.append(p); _contexts.append(c); lock.unlock() }
        var prompts: [String] { lock.lock(); defer { lock.unlock() }; return _prompts }
        var contexts: [NoteContext] { lock.lock(); defer { lock.unlock() }; return _contexts }
    }

    /// `reply` is what the fake model returns (it can ignore the highlights).
    private func deps(_ seen: Seen, reply: String = PipelineTests.validNote) -> PipelineDeps {
        PipelineDeps(
            convertToWav: { _, dest in
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data([0]).write(to: dest)
            },
            transcribe: { _, _ in ["segments": [["speaker": "SPEAKER_00", "text": "hello world"]]] },
            ollamaReachable: { _ in true },
            summarise: { transcript, _, _, context in
                seen.add(context.prompt(transcript: transcript), context)
                return reply
            },
            audioDurationSeconds: { _ in nil })
    }

    func testTypedLineReachesPromptBuildThroughProcessOneAndShowsAsHighlight() async throws {
        let env = try makeEnv()
        let url = env.recordings.appendingPathComponent("Meeting 2026-10-05 10.00.00.wav")
        try Data([0, 1, 2, 3]).write(to: url)
        // The recorder keys the sidecar on the base the pipeline will derive.
        let base = DistavoState.baseFor(recordingsDir: env.recordings, path: url)
        try pad.save(workDir: env.work, base: base)

        let seen = Seen()
        // The model ignores the instruction: the safety net must still add the line.
        let r = await Pipeline.processOne(path: url, config: env.config, deps: deps(seen),
                                          stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(r.status, .done, r.message)
        XCTAssertTrue(seen.prompts[0].contains("01:15 - ask about notice period"), "typed text reached Prompt.build")
        XCTAssertTrue(seen.prompts[0].contains("[MUST INCLUDE] 06:40 - decision: go with option B"))
        let note = try String(contentsOf: env.notes.appendingPathComponent("\(base).md"), encoding: .utf8)
        XCTAssertTrue(note.contains("## Highlights"))
        XCTAssertTrue(note.contains("ask about notice period"))
        XCTAssertTrue(note.contains("⭐ **06:40** decision: go with option B"))
    }

    func testModelThatComplied_isNotDuplicated() async throws {
        let env = try makeEnv()
        let url = env.recordings.appendingPathComponent("a.wav")
        try Data([0, 1, 2, 3]).write(to: url)
        try pad.save(workDir: env.work, base: "a")
        let complied = PipelineTests.validNote.replacingOccurrences(
            of: "# Meeting notes\n", with: "# Meeting notes\n\n## Highlights\n- **01:15** ask about notice period - discussed\n")
        let r = await Pipeline.processOne(path: url, config: env.config, deps: deps(Seen(), reply: complied),
                                          stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(r.status, .done, r.message)
        let note = try String(contentsOf: env.notes.appendingPathComponent("a.md"), encoding: .utf8)
        XCTAssertEqual(note.components(separatedBy: "## Highlights").count - 1, 1)
        XCTAssertTrue(note.contains("discussed"))
    }

    func testNoSidecarMeansNoScratchpadInTheContextOrPrompt() async throws {
        let env = try makeEnv()
        let url = env.recordings.appendingPathComponent("b.wav")
        try Data([0, 1, 2, 3]).write(to: url)
        let seen = Seen()
        let r = await Pipeline.processOne(path: url, config: env.config, deps: deps(seen),
                                          stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(r.status, .done, r.message)
        XCTAssertNil(seen.contexts[0].scratchpad)
        XCTAssertFalse(seen.prompts[0].contains("Notes typed"))
        let note = try String(contentsOf: env.notes.appendingPathComponent("b.md"), encoding: .utf8)
        XCTAssertFalse(note.contains("Highlights"))
    }

    func testRegenerateKeepsTheHighlights() async throws {
        let env = try makeEnv()
        try FileManager.default.createDirectory(at: env.notes, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: env.work, withIntermediateDirectories: true)
        try "SPEAKER_00: hello there".write(to: Pipeline.cachedTranscriptURL(workDir: env.work, base: "demo"),
                                            atomically: true, encoding: .utf8)
        try "# Meeting notes\n\nOLD".write(to: env.notes.appendingPathComponent("demo.md"),
                                           atomically: true, encoding: .utf8)
        try pad.save(workDir: env.work, base: "demo")

        let seen = Seen()
        let r = await Pipeline.regenerate(base: "demo", options: .init(), config: env.config, deps: deps(seen))
        XCTAssertEqual(r.status, .done, r.message)
        XCTAssertTrue(seen.prompts[0].contains("01:15 - ask about notice period"), "typed text reached Prompt.build")
        let note = try String(contentsOf: env.notes.appendingPathComponent("demo.md"), encoding: .utf8)
        XCTAssertTrue(note.contains("## Highlights"))
        XCTAssertTrue(note.contains("⭐ **06:40** decision: go with option B"))
    }
}
