import XCTest
@testable import DistavoCore

/// Vikunja #6772 (a 67-minute meeting, microphone only): the chair said "standing in for Sam" and the note named
/// her "the note owner"; the real owner's name ("Marc") was heard as "Prince" and became a separate person and
/// task owner. Two fixes, both inert while `note_owner` is unset ("Me" is the default, or empty):
///  1. the owner's name and first name seed the meeting terms (transcriber prompt, fuzzy pass, summary glossary);
///  2. the prompt says the owner is the configured one, and "standing in for ..." never makes a speaker the owner.
final class OwnerIdentityTests: XCTestCase {

    // MARK: 1. seeding

    func testFullNameSeedsNameAndFirstName() {
        XCTAssertEqual(OwnerIdentity.terms(noteOwner: "Marc Riera"), ["Marc Riera", "Marc"])
        XCTAssertEqual(OwnerIdentity.terms(noteOwner: "  Marc  "), ["Marc"])
    }

    func testUnsetOwnerSeedsNothing() {
        for unset in ["", "  ", "Me", "me", "unknown", "I", "The note owner"] {
            XCTAssertEqual(OwnerIdentity.terms(noteOwner: unset), [], "\"\(unset)\"")
            XCTAssertFalse(OwnerIdentity.isConfigured(unset), "\"\(unset)\"")
        }
        XCTAssertEqual(OwnerIdentity.terms(noteOwner: Config().noteOwner), [], "the shipped default is unset")
    }

    private func makeConfig(owner: String?) throws -> (Config, URL) {
        let dir = TestTemp.root.appendingPathComponent("distavo-owner-\(UUID().uuidString)")
        var cfg = Config()
        cfg.recordingsDir = dir.appendingPathComponent("rec").path
        cfg.notesDir = dir.appendingPathComponent("notes").path
        cfg.workDir = dir.appendingPathComponent("work").path
        if let owner { cfg.noteOwner = owner }
        cfg.transcribe.vocabulary = ["GlobalTerm"]
        cfg.transcribe.fuzzyVocabulary = true
        for d in [cfg.recordingsDir, cfg.notesDir, cfg.workDir] {
            try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        }
        return (cfg, dir)
    }

    private func run(owner: String?, participants: String?) async throws -> (vocab: [String], glossary: [String], fuzzy: String) {
        let (cfg, dir) = try makeConfig(owner: owner)
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = URL(fileURLWithPath: cfg.recordingsDir).appendingPathComponent("demo.opus")
        try Data(repeating: 1, count: 64).write(to: input)
        if let participants {
            try SpeakerHints(count: nil, participants: participants).save(workDir: URL(fileURLWithPath: cfg.workDir), base: "demo")
        }
        let seenVocab = Box<[String]>([]), seenGlossary = Box<[String]>([]), seenTranscript = Box<String>("")
        let deps = PipelineDeps(
            convertToWav: { _, dest in
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data([0]).write(to: dest)
            },
            transcribe: { _, t in
                seenVocab.set(t.vocabulary)
                return ["segments": [["speaker": "SPEAKER_00", "text": "Thank you Mark Riera for joining today"]]]
            },
            ollamaReachable: { _ in true },
            summarise: { transcript, _, _, context in
                seenGlossary.set(context.glossary)
                seenTranscript.set(transcript)
                return PipelineTests.validNote
            },
            audioDurationSeconds: { _ in 60 })
        let r = await Pipeline.processOne(path: input, config: cfg, deps: deps, stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(r.status, .done, r.message)
        return (seenVocab.value, seenGlossary.value, seenTranscript.value)
    }

    func testOwnerNameReachesTranscriberPromptSummaryGlossaryAndFuzzyPass() async throws {
        let out = try await run(owner: "Marc Riera", participants: "Annika")
        // This meeting's names first (participants), then the owner, then the global vocabulary.
        XCTAssertEqual(out.vocab, ["Annika", "Marc Riera", "Marc", "GlobalTerm"])
        XCTAssertEqual(out.glossary, out.vocab)
        // The fuzzy post-pass (#3950) snaps a near-miss spelling to the seeded full name (it only takes terms of 5+ letters).
        XCTAssertTrue(out.fuzzy.contains("Marc Riera for joining"), out.fuzzy)
    }

    func testUnsetOwnerLeavesTheVocabularyAsBefore() async throws {
        let unset = try await run(owner: nil, participants: "Annika")
        XCTAssertEqual(unset.vocab, ["Annika", "GlobalTerm"])
        let empty = try await run(owner: "", participants: nil)
        XCTAssertEqual(empty.vocab, ["GlobalTerm"])
    }

    func testRegenerateGlossaryCarriesTheOwnerToo() async throws {
        let (cfg, dir) = try makeConfig(owner: "Marc Riera")
        defer { try? FileManager.default.removeItem(at: dir) }
        let work = URL(fileURLWithPath: cfg.workDir)
        try "[SPEAKER_00]\nhello there\n".write(to: Pipeline.cachedTranscriptURL(workDir: work, base: "demo"),
                                               atomically: true, encoding: .utf8)
        try "# Meeting notes\n\nOLD".write(to: URL(fileURLWithPath: cfg.notesDir).appendingPathComponent("demo.md"),
                                           atomically: true, encoding: .utf8)
        let seen = Box<[String]>([])
        let deps = PipelineDeps(
            convertToWav: { _, _ in }, transcribe: { _, _ in [:] }, ollamaReachable: { _ in true },
            summarise: { _, _, _, context in seen.set(context.glossary); return PipelineTests.validNote })
        let r = await Pipeline.regenerate(base: "demo", options: .init(), config: cfg, deps: deps)
        XCTAssertEqual(r.status, .done, r.message)
        XCTAssertEqual(seen.value, ["Marc Riera", "Marc", "GlobalTerm"])
    }

    // MARK: 2. owner inference
    //
    // The rule rides the `customInstruction` channel (as the title/tags request of #2954 does): it reaches Ollama,
    // Gemma and Apple's on-device model, is counted in their budgets, and leaves `Prompt.build` untouched, so every
    // prompt with no owner configured stays byte-identical (pinned elsewhere by hash).

    private let fixture = """
    [SPEAKER_00]
    Hi everyone, I'm standing in for Sam today, she is on leave. Let's start with the agenda.

    [SPEAKER_01]
    Thanks. Marc here, I can take the first two actions.
    """

    private func notesAskingForMetadata() -> NotesConfig {
        var notes = NotesConfig()
        notes.frontmatter = true; notes.autoTitle = true; notes.autoTags = true
        XCTAssertTrue(notes.asksModelForMetadata)
        return notes
    }

    func testInstructionNamesTheConfiguredOwnerAndRejectsStandingInFor() throws {
        let rule = try XCTUnwrap(OwnerIdentity.instruction(noteOwner: "Marc"))
        for phrase in ["standing in for", "sitting in for", "on behalf of"] {
            XCTAssertTrue(rule.contains("\"\(phrase)\""), phrase)
        }
        XCTAssertTrue(rule.contains("Marc"))
        XCTAssertTrue(rule.contains("never a separate person or task owner"))
        XCTAssertNil(OwnerIdentity.instruction(noteOwner: "Me"))
        XCTAssertNil(OwnerIdentity.instruction(noteOwner: ""))
    }

    func testMergedInstructionReachesTheFinalPromptAfterTheTranscriptOnBothTemplates() {
        let instruction = OwnerIdentity.merged(nil, noteOwner: "Marc", notes: NotesConfig())
        XCTAssertNotNil(instruction)
        for style in [Prompt.Style.classic, .factsFirst] {
            let p = Prompt.build(transcript: fixture, noteOwner: "Marc", userSpeaker: "unknown", style: style,
                                 customInstruction: instruction)
            XCTAssertTrue(p.contains("never a separate person or task owner"), "\(style)")
            // It is the last thing the model reads, after the transcript that says "standing in for Sam".
            XCTAssertLessThan(p.range(of: "I'm standing in for Sam")!.lowerBound,
                              p.range(of: "\"standing in for\"")!.lowerBound, "\(style)")
        }
    }

    func testUnsetOwnerAddsNothingAndKeepsThePromptByteIdentical() {
        var notes = NotesConfig()
        for owner in ["Me", "", "unknown"] {
            XCTAssertNil(OwnerIdentity.merged(nil, noteOwner: owner, notes: notes), owner)
            XCTAssertEqual(OwnerIdentity.merged("Focus on risks.", noteOwner: owner, notes: notes), "Focus on risks.")
            let classic = Prompt.build(transcript: fixture, noteOwner: owner, userSpeaker: "unknown",
                                       customInstruction: OwnerIdentity.merged(nil, noteOwner: owner, notes: notes))
            XCTAssertEqual(classic, Prompt.template
                .replacingOccurrences(of: "{note_owner}", with: owner)
                .replacingOccurrences(of: "{user_speaker}", with: "unknown")
                .replacingOccurrences(of: "{transcript_text}", with: fixture), "classic \"\(owner)\"")
        }
        notes = notesAskingForMetadata()
        XCTAssertEqual(OwnerIdentity.merged(nil, noteOwner: "Me", notes: notes), NoteMeta.requestText(notes))
        XCTAssertEqual(OwnerIdentity.merged("x", noteOwner: "Me", notes: notes),
                       NoteMeta.mergedInstruction("x", notes: notes), "unset = exactly the old merge")
    }

    func testOwnerRuleSurvivesTheCapWithAUserInstructionAndTheTitleRequest() throws {
        let notes = notesAskingForMetadata()
        let long = String(repeating: "Focus on the risks and the budget. ", count: 60)
        let merged = try XCTUnwrap(OwnerIdentity.merged(long, noteOwner: "Marc", notes: notes))
        XCTAssertLessThanOrEqual(merged.count, Prompt.maxCustomInstructionChars)
        XCTAssertTrue(merged.contains(try XCTUnwrap(OwnerIdentity.instruction(noteOwner: "Marc"))), "owner rule kept whole")
        XCTAssertTrue(merged.contains(NoteMeta.requestText(notes)), "title request kept whole")
        XCTAssertTrue(merged.contains("Focus on the risks"), "user text keeps the room that is left")
    }

    func testProcessOneAndRegenerateHandTheRuleToTheSummariser() async throws {
        let (cfg, dir) = try makeConfig(owner: "Marc Riera")
        defer { try? FileManager.default.removeItem(at: dir) }
        let work = URL(fileURLWithPath: cfg.workDir)
        try "[SPEAKER_00]\nhello there\n".write(to: Pipeline.cachedTranscriptURL(workDir: work, base: "demo"),
                                               atomically: true, encoding: .utf8)
        try "# Meeting notes\n\nOLD".write(to: URL(fileURLWithPath: cfg.notesDir).appendingPathComponent("demo.md"),
                                           atomically: true, encoding: .utf8)
        let seen = Box<String?>(nil)
        let deps = PipelineDeps(
            convertToWav: { _, _ in }, transcribe: { _, _ in [:] }, ollamaReachable: { _ in true },
            summarise: { _, _, _, context in seen.set(context.customInstruction); return PipelineTests.validNote })
        let r = await Pipeline.regenerate(base: "demo", options: RegenerateOptions(customInstruction: "Be brief."),
                                          config: cfg, deps: deps)
        XCTAssertEqual(r.status, .done, r.message)
        let regenerated = try XCTUnwrap(seen.value)
        XCTAssertTrue(regenerated.contains("never a separate person or task owner"), regenerated)
        XCTAssertTrue(regenerated.contains("Be brief."), regenerated)

        // processOne: the same, from a fresh recording.
        let input = URL(fileURLWithPath: cfg.recordingsDir).appendingPathComponent("fresh.opus")
        try Data(repeating: 1, count: 64).write(to: input)
        seen.set(nil)
        let live = PipelineDeps(
            convertToWav: { _, dest in
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data([0]).write(to: dest)
            },
            transcribe: { _, _ in ["segments": [["speaker": "SPEAKER_00", "text": "I'm standing in for Sam"]]] },
            ollamaReachable: { _ in true },
            summarise: { _, _, _, context in seen.set(context.customInstruction); return PipelineTests.validNote },
            audioDurationSeconds: { _ in 60 })
        let p = await Pipeline.processOne(path: input, config: cfg, deps: live, stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(p.status, .done, p.message)
        XCTAssertTrue(try XCTUnwrap(seen.value).contains("never a separate person or task owner"))
    }

    func testUnsetOwnerLeavesTheSummariserInstructionNil() async throws {
        let (cfg, dir) = try makeConfig(owner: nil)   // the default owner, "Me"
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = URL(fileURLWithPath: cfg.recordingsDir).appendingPathComponent("fresh.opus")
        try Data(repeating: 1, count: 64).write(to: input)
        let seen = Box<String?>("sentinel")
        let live = PipelineDeps(
            convertToWav: { _, dest in
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data([0]).write(to: dest)
            },
            transcribe: { _, _ in ["segments": [["speaker": "SPEAKER_00", "text": "hello there"]]] },
            ollamaReachable: { _ in true },
            summarise: { _, _, _, context in seen.set(context.customInstruction); return PipelineTests.validNote },
            audioDurationSeconds: { _ in 60 })
        let p = await Pipeline.processOne(path: input, config: cfg, deps: live, stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(p.status, .done, p.message)
        XCTAssertNil(seen.value)
    }
}

private final class Box<T>: @unchecked Sendable {
    private let l = NSLock(); private var v: T
    init(_ v: T) { self.v = v }
    func set(_ x: T) { l.lock(); v = x; l.unlock() }
    var value: T { l.lock(); defer { l.unlock() }; return v }
}
