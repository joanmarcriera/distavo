import XCTest
@testable import DistavoCore

/// `StepVerifier` (D059): every bullet or row of the plan / follow-up / key-people sections needs a quote
/// from the transcript. Synthetic transcript and names only.
final class StepVerifierTests: XCTestCase {
    private let transcript = """
    SPEAKER_00: Good morning everyone, this is the weekly planning call for the Larkfield garden project.
    SPEAKER_01: Oskar said he would ask two suppliers by Friday and send the numbers to the group.
    SPEAKER_00: Petra will order more gloves and a second wheelbarrow this week.
    SPEAKER_01: Nadia Ferris offered to print the posters for the open day in December.
    SPEAKER_00: La Núria s'encarregarà de les cançons de Nadal per a la jornada.
    """

    private func note(_ section: String, _ body: String) -> String {
        "# Garden call\n\n## Summary\nTrees arrive.\n\n## \(section)\n\(body)\n\n## Risks and concerns\n- Pond liner tear\n"
    }

    func testQuotedAndFoundIsKept() {
        let n = note("30-minute post-meeting plan", "- Chase the supplier quotes (\"ask two suppliers by Friday\")")
        let r = StepVerifier.verify(n, transcript: transcript)
        XCTAssertEqual(r.text, n)
        XCTAssertEqual(r.kept, 1)
    }

    func testQuoteNotInTranscriptIsMarkedUnverified() {
        let n = note("30-minute post-meeting plan", "- Book a van (\"we must book the van today\")")
        let r = StepVerifier.verify(n, transcript: transcript)
        XCTAssertTrue(r.text.contains("- Book a van (\"we must book the van today\") [unverified]"), r.text)
        XCTAssertEqual(r.unverified, 1)
    }

    func testNoQuoteIsRemovedAndEmptiedSectionSaysSo() {
        let n = note("Highest-ROI follow-up", "- Send a thank-you email to everyone")
        let r = StepVerifier.verify(n, transcript: transcript)
        XCTAssertFalse(r.text.contains("thank-you email"))
        XCTAssertTrue(r.text.contains("## Highest-ROI follow-up\n\(StepVerifier.emptySection)\n"), r.text)
        XCTAssertEqual(r.removed, 1)
    }

    func testTableRowsAreCheckedAndAnEmptiedTableIsReplaced() {
        let body = """
        | Priority | Next move | Why it matters | Timebox | Evidence | Confidence |
        |---|---|---|---|---|---|
        | 1 | Get quotes | Budget | 2 days | "ask two suppliers by Friday" | High |
        | 2 | Hire a gardener | Speed | 1 week | none | Low |
        """
        let r = StepVerifier.verify(note("Highest-ROI follow-up", body), transcript: transcript)
        XCTAssertTrue(r.text.contains("| 1 | Get quotes |"))
        XCTAssertFalse(r.text.contains("Hire a gardener"))
        XCTAssertTrue(r.text.contains("| Priority | Next move |"), "the header stays while a row is left")
        let empty = StepVerifier.verify(note("Highest-ROI follow-up", """
        | Priority | Next move | Why it matters | Timebox | Evidence | Confidence |
        |---|---|---|---|---|---|
        | 2 | Hire a gardener | Speed | 1 week | none | Low |
        """), transcript: transcript)
        XCTAssertFalse(empty.text.contains("| Priority |"))
        XCTAssertTrue(empty.text.contains(StepVerifier.emptySection))
    }

    func testKeyPeopleHeadingByPrefixAndInCatalanAndSpanish() {
        for heading in ["Key people and organisations", "Persones clau i organitzacions", "Personas clave y organizaciones",
                        "Pla posterior de 30 minuts", "Seguimiento de mayor valor"] {
            let n = note(heading, "- Nadia Ferris, posters\n- Oskar (\"ask two suppliers by Friday\")")
            let r = StepVerifier.verify(n, transcript: transcript)
            XCTAssertFalse(r.text.contains("Nadia Ferris, posters"), heading)
            XCTAssertTrue(r.text.contains("- Oskar (\"ask two suppliers by Friday\")"), heading)
        }
    }

    func testAccentedQuoteMatches() {
        // The task 2670 bug: an ASCII-only pattern missed accented words.
        let n = note("Persones clau", "- Núria (“s’encarregarà de les cançons de Nadal”)")
        let r = StepVerifier.verify(n, transcript: transcript)
        XCTAssertEqual(r.text, n)
        XCTAssertEqual(r.kept, 1)
    }

    func testTasksAndOtherSectionsAreByteIdentical() {
        let n = "# Call\n\n## Action items\n- Order gloves\n- Book a van\n\n## Decisions made\n- Patch the liner now\n"
        XCTAssertEqual(StepVerifier.verify(n, transcript: transcript).text, n)
        XCTAssertEqual(StepVerifier.verify(n, transcript: transcript).checked, 0)
    }

    func testTextOutsideTheSectionsIsByteIdentical() {
        let n = note("30-minute post-meeting plan", "Do these first:\n- Chase quotes\n- Order gloves (\"Petra will order more gloves\")")
        let r = StepVerifier.verify(n, transcript: transcript)
        XCTAssertTrue(r.text.hasPrefix("# Garden call\n\n## Summary\nTrees arrive.\n\n## 30-minute post-meeting plan\nDo these first:\n"))
        XCTAssertTrue(r.text.hasSuffix("\n\n## Risks and concerns\n- Pond liner tear\n"))
    }

    func testIdempotent() {
        let n = note("30-minute post-meeting plan",
                     "- Chase quotes (\"ask two suppliers by Friday\")\n- Book a van (\"book the van today\")\n- Hire help")
        let once = StepVerifier.verify(n, transcript: transcript).text
        XCTAssertEqual(StepVerifier.verify(once, transcript: transcript).text, once)
    }

    func testShortTranscriptIsNotJudged() {
        let n = note("30-minute post-meeting plan", "- Hire help")
        XCTAssertEqual(StepVerifier.verify(n, transcript: "SPEAKER_00: hello there").text, n)
    }

    func testFooterNote() {
        let r = StepVerifier.Result(text: "", kept: 2, unverified: 1, removed: 3)
        XCTAssertEqual(StepVerifier.footerNote(r), "Plan steps checked against the transcript: 2 kept, 1 unverified, 3 removed (no quote)")
        XCTAssertNil(StepVerifier.footerNote(StepVerifier.Result(text: "", kept: 0, unverified: 0, removed: 0)))
    }

    func testKeyOffIsByteIdenticalAndPromptUnchanged() throws {
        let n = note("30-minute post-meeting plan", "- Hire help")
        let off = NoteRefinements.apply(summary: n, transcript: transcript,
                                        context: NoteContext(noteOwner: "Me", userSpeaker: "SPEAKER_00"), config: Config())
        XCTAssertEqual(off.text, n)
        XCTAssertTrue(off.notes.isEmpty)
        var cfg = Config()
        cfg.summarise.verifySteps = true
        // On-device target: the pipeline leaves context.verifySteps false, so nothing is checked.
        let onDevice = NoteRefinements.apply(summary: n, transcript: transcript,
                                             context: NoteContext(noteOwner: "Me", userSpeaker: "SPEAKER_00"), config: cfg)
        XCTAssertEqual(onDevice.text, n)
        var ollama = NoteContext(noteOwner: "Me", userSpeaker: "SPEAKER_00")
        ollama.verifySteps = true
        let on = NoteRefinements.apply(summary: n, transcript: transcript, context: ollama, config: cfg)
        XCTAssertFalse(on.text.contains("Hire help"))
        XCTAssertEqual(on.notes.count, 1)
        // Prompt: byte-identical unless the context asks for quotes, in both prompt styles.
        for style in [Prompt.Style.classic, .factsFirst] {
            var ctx = NoteContext(noteOwner: "Me", userSpeaker: "SPEAKER_00", promptStyle: style)
            let before = ctx.prompt(transcript: "T")
            ctx.verifySteps = true
            let after = ctx.prompt(transcript: "T")
            XCTAssertNotEqual(before, after)
            XCTAssertTrue(after.contains(StepVerifier.promptSentence))
            XCTAssertFalse(before.contains(StepVerifier.promptSentence))
        }
        let old = try JSONDecoder().decode(SummariseConfig.self, from: Data("{}".utf8))
        XCTAssertFalse(old.verifySteps)
        XCTAssertTrue(Config.recommendedForThisMac().summarise.verifySteps)
    }
    /// A2: processOne end to end with a stub summariser: the counts line reaches the footer, the prompt asked.
    func testPipelineFooterCarriesTheCounts() async throws {
        let root = TestTemp.root.appendingPathComponent("distavo-steps-\(UUID().uuidString)")
        let rec = root.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: rec, withIntermediateDirectories: true)
        let input = rec.appendingPathComponent("garden.opus")
        try Data([0, 1, 2, 3]).write(to: input)
        var cfg = Config()
        cfg.recordingsDir = rec.path
        cfg.notesDir = root.appendingPathComponent("notes").path
        cfg.workDir = root.appendingPathComponent("work").path
        cfg.summarise.verifySteps = true
        let lines = transcript.components(separatedBy: "\n")
        let result: [String: Any] = ["segments": lines.enumerated().map { i, line in
            ["start": Double(i * 10), "end": Double(i * 10 + 9), "speaker": String(line.prefix(10)),
             "text": String(line.dropFirst(12))] as [String: Any]
        }]
        final class Box: @unchecked Sendable { var prompts: [String] = [] }
        let box = Box()
        let summary = PipelineTests.validNote
            + "\n\n## 30-minute post-meeting plan\n- Chase quotes (\"ask two suppliers by Friday\")\n- Hire help\n"
        let deps = PipelineDeps(
            convertToWav: { _, dest in
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data([0]).write(to: dest)
            },
            transcribe: { _, _ in result },
            ollamaReachable: { _ in true },
            summarise: { input, _, _, context in box.prompts.append(context.prompt(transcript: input)); return summary },
            audioDurationSeconds: { _ in nil })
        let r = await Pipeline.processOne(path: input, config: cfg, deps: deps, stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(r.status, .done, r.message)
        let note = try String(contentsOf: XCTUnwrap(r.notePath), encoding: .utf8)
        XCTAssertTrue(note.contains("Plan steps checked against the transcript: 1 kept, 0 unverified, 1 removed (no quote)"), note)
        XCTAssertFalse(note.contains("Hire help"))
        XCTAssertTrue(box.prompts.first?.contains(StepVerifier.promptSentence) ?? false)
    }
    // Review round 2 (drive 2026-11-23).
    func testGuillemetsAndCurlySingleQuotesCount() {
        let n = note("Pla posterior de 30 minuts",
                     "- Demanar pressupostos («ask two suppliers by Friday»)\n- Cartells (‘Nadia Ferris offered to print the posters’)")
        let r = StepVerifier.verify(n, transcript: transcript)
        XCTAssertEqual(r.text, n)
        XCTAssertEqual(r.kept, 2)
    }

    func testAnIndentedChildBelongsToItsBullet() {
        let n = note("30-minute post-meeting plan",
                     "- Chase the quotes\n  - Oskar: \"ask two suppliers by Friday\"\n- Hire help\n  - nobody said this")
        let r = StepVerifier.verify(n, transcript: transcript)
        XCTAssertTrue(r.text.contains("- Chase the quotes\n  - Oskar: \"ask two suppliers by Friday\""), r.text)
        XCTAssertFalse(r.text.contains("Hire help"))
        XCTAssertFalse(r.text.contains("nobody said this"), "the child goes with its parent")
        XCTAssertEqual(r.kept, 1); XCTAssertEqual(r.removed, 1)
    }

    func testQuotesAreCheckedBeforeDatesAreAdded() {
        var cfg = Config()
        cfg.summarise.resolveRelativeDates = true
        var ctx = NoteContext(noteOwner: "Me", userSpeaker: "SPEAKER_00")
        ctx.verifySteps = true
        var c = DateComponents(); c.year = 2026; c.month = 11; c.day = 18; c.hour = 9
        ctx.meetingDate = Calendar(identifier: .gregorian).date(from: c)
        let n = note("30-minute post-meeting plan", "- [ ] Chase quotes (\"ask two suppliers by Friday\")")
        let out = NoteRefinements.apply(summary: n, transcript: transcript, context: ctx, config: cfg)
        XCTAssertFalse(out.text.contains("[unverified]"), out.text)
    }

    func testATagLineDoesNotEndTheSection() {
        let n = note("30-minute post-meeting plan", "#followup\n- Hire help")
        XCTAssertFalse(StepVerifier.verify(n, transcript: transcript).text.contains("Hire help"))
    }
}
