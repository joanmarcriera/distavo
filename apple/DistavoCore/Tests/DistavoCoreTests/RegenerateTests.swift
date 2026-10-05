import XCTest
@testable import DistavoCore

/// Thread-safe call/phase/prompt recorder for the fake dependencies.
private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var _convert = 0, _transcribe = 0, _summarise = 0
    private var _phases: [ProcessingPhase] = []
    private var _contexts: [NoteContext] = []
    private var _targets: [SummariseTarget] = []
    func convert() { lock.lock(); _convert += 1; lock.unlock() }
    func transcribe() { lock.lock(); _transcribe += 1; lock.unlock() }
    func summarise(_ c: NoteContext, _ t: SummariseTarget) {
        lock.lock(); _summarise += 1; _contexts.append(c); _targets.append(t); lock.unlock()
    }
    func phase(_ p: ProcessingPhase) { lock.lock(); _phases.append(p); lock.unlock() }
    var converts: Int { lock.lock(); defer { lock.unlock() }; return _convert }
    var transcribes: Int { lock.lock(); defer { lock.unlock() }; return _transcribe }
    var summarises: Int { lock.lock(); defer { lock.unlock() }; return _summarise }
    var phases: [ProcessingPhase] { lock.lock(); defer { lock.unlock() }; return _phases }
    var contexts: [NoteContext] { lock.lock(); defer { lock.unlock() }; return _contexts }
    var targets: [SummariseTarget] { lock.lock(); defer { lock.unlock() }; return _targets }
}

/// Vikunja #2947: regenerate re-summarises from the cached transcript only and
/// keeps the previous note.
final class RegenerateTests: XCTestCase {

    private static let newNote = PipelineTests.validNote.replacingOccurrences(of: "project timelines", with: "REGENERATED timelines")
    private let oldNote = "# Meeting notes\n\nOLD NOTE BODY"

    private func makeEnv(transcript: String? = "SPEAKER_00: hello there",
                         note: String? = "# Meeting notes\n\nOLD NOTE BODY") throws -> (Config, URL, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("distavo-regen-\(UUID().uuidString)")
        var cfg = Config()
        cfg.recordingsDir = root.appendingPathComponent("recordings").path
        cfg.notesDir = root.appendingPathComponent("notes").path
        cfg.workDir = root.appendingPathComponent("work").path
        let notes = URL(fileURLWithPath: cfg.notesDir), work = URL(fileURLWithPath: cfg.workDir)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        if let transcript {
            try transcript.write(to: Pipeline.cachedTranscriptURL(workDir: work, base: "demo"),
                                 atomically: true, encoding: .utf8)
        }
        if let note { try note.write(to: notes.appendingPathComponent("demo.md"), atomically: true, encoding: .utf8) }
        return (cfg, notes, work)
    }

    private func deps(_ calls: Calls, reachable: Bool = true,
                      summarise: @escaping (String) async throws -> String = { _ in RegenerateTests.newNote }) -> PipelineDeps {
        PipelineDeps(
            convertToWav: { _, _ in calls.convert() },
            transcribe: { _, _ in calls.transcribe(); return [:] },
            ollamaReachable: { _ in reachable },
            summarise: { transcript, target, _, context in
                calls.summarise(context, target)
                return try await summarise(transcript)
            },
            onPhase: { calls.phase($0) })
    }

    private func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }
    private func backups(_ notes: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: notes, includingPropertiesForKeys: nil)) ?? [])
            .filter { NoteVersions.isBackupName($0.lastPathComponent) }
    }

    func testRegenerateNeverTranscribesAndKeepsPreviousNote() async throws {
        let (cfg, notes, _) = try makeEnv()
        let calls = Calls()
        let result = await Pipeline.regenerate(base: "demo", options: .init(), config: cfg, deps: deps(calls))
        XCTAssertEqual(result.status, .done, result.message)
        XCTAssertEqual(calls.converts, 0)
        XCTAssertEqual(calls.transcribes, 0)
        XCTAssertEqual(calls.summarises, 1)
        // Only the summarising stage is reported: no converting / transcribing step.
        XCTAssertEqual(calls.phases, [.summarising])
        XCTAssertEqual(read(notes.appendingPathComponent("demo.md")), Self.newNote)
        let kept = backups(notes)
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(read(kept[0]), oldNote)
        XCTAssertTrue(result.message.contains(kept[0].lastPathComponent))
        // The cached transcript is what was summarised.
        XCTAssertEqual(calls.contexts.count, 1)
    }

    func testRegenerateTwiceKeepsBothBackupsEvenInTheSameSecond() async throws {
        let (cfg, notes, _) = try makeEnv()
        let calls = Calls()
        let now = Date()
        _ = await Pipeline.regenerate(base: "demo", options: .init(), config: cfg, deps: deps(calls), now: now)
        let second = await Pipeline.regenerate(base: "demo", options: .init(), config: cfg, deps: deps(calls), now: now)
        XCTAssertEqual(second.status, .done)
        XCTAssertEqual(backups(notes).count, 2, "an existing backup must never be overwritten")
        XCTAssertTrue(backups(notes).contains { read($0) == oldNote })
    }

    func testMissingTranscriptIsAClearErrorAndTouchesNothing() async throws {
        let (cfg, notes, work) = try makeEnv(transcript: nil)
        let calls = Calls()
        let result = await Pipeline.regenerate(base: "demo", options: .init(), config: cfg, deps: deps(calls))
        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.message.contains("no saved transcript"), result.message)
        XCTAssertEqual(calls.summarises + calls.transcribes + calls.converts, 0)
        XCTAssertEqual(read(notes.appendingPathComponent("demo.md")), oldNote)
        XCTAssertTrue(backups(notes).isEmpty)
        // No `.failed` marker: iterPending would skip the recording forever.
        let state = try DistavoState.Store(stateDir: work.appendingPathComponent(".state"), notesDir: notes)
        XCTAssertFalse(state.isFailed("demo"))
    }

    func testDeferredSummariserLeavesNoteUntouched() async throws {
        let (cfg, notes, work) = try makeEnv()
        let calls = Calls()
        // Server Ollama offline, local fallback off => chooseSummariser defers.
        let result = await Pipeline.regenerate(base: "demo", options: .init(), config: cfg,
                                               deps: deps(calls, reachable: false))
        XCTAssertEqual(result.status, .deferredNeedLocal)
        XCTAssertEqual(calls.summarises, 0)
        XCTAssertEqual(read(notes.appendingPathComponent("demo.md")), oldNote)
        XCTAssertTrue(backups(notes).isEmpty)
        let state = try DistavoState.Store(stateDir: work.appendingPathComponent(".state"), notesDir: notes)
        XCTAssertFalse(state.isFailed("demo"))
    }

    func testRetryableErrorDefersAndSummariserErrorKeepsNote() async throws {
        let (cfg, notes, work) = try makeEnv()
        let retry = await Pipeline.regenerate(
            base: "demo", options: .init(), config: cfg,
            deps: deps(Calls(), summarise: { _ in throw RetryableDependencyError("model downloading") }))
        XCTAssertEqual(retry.status, .deferredNeedLocal)
        let boom = await Pipeline.regenerate(
            base: "demo", options: .init(), config: cfg,
            deps: deps(Calls(), summarise: { _ in throw OllamaError("boom") }))
        XCTAssertEqual(boom.status, .failed)
        XCTAssertEqual(read(notes.appendingPathComponent("demo.md")), oldNote)
        XCTAssertTrue(backups(notes).isEmpty)
        let state = try DistavoState.Store(stateDir: work.appendingPathComponent(".state"), notesDir: notes)
        XCTAssertFalse(state.isFailed("demo"))
    }

    func testInvalidSummaryIsQuarantinedAndNoteKept() async throws {
        let (cfg, notes, work) = try makeEnv()
        let result = await Pipeline.regenerate(
            base: "demo", options: .init(), config: cfg, deps: deps(Calls(), summarise: { _ in "x" }))
        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.message.contains("rejected"), result.message)
        XCTAssertEqual(read(notes.appendingPathComponent("demo.md")), oldNote)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: work.appendingPathComponent("demo.regenerate-rejected.md").path))
    }

    func testOptionsReachTheSummariser() async throws {
        let (cfg, _, _) = try makeEnv()
        let calls = Calls()
        let options = RegenerateOptions(promptStyle: .factsFirst, model: "big-model:1b", backend: "server",
                                        customInstruction: "  Focus on action items only.  ", templateID: "t1")
        let result = await Pipeline.regenerate(base: "demo", options: options, config: cfg, deps: deps(calls))
        XCTAssertEqual(result.status, .done, result.message)
        let context = try XCTUnwrap(calls.contexts.first)
        XCTAssertEqual(context.promptStyle, .factsFirst)
        XCTAssertEqual(context.customInstruction, "  Focus on action items only.  ")
        XCTAssertTrue(context.prompt(transcript: "T").contains("Focus on action items only."))
        XCTAssertEqual(calls.targets.first, .ollama(url: cfg.summarise.server.url, model: "big-model:1b"))
    }

    func testOnDeviceBackendOffIsRefusedNotSilentlySwitched() async throws {
        let (cfg, notes, _) = try makeEnv()
        let calls = Calls()
        let result = await Pipeline.regenerate(base: "demo", options: .init(backend: "embedded"),
                                               config: cfg, deps: deps(calls))
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(calls.summarises, 0)
        XCTAssertEqual(read(notes.appendingPathComponent("demo.md")), oldNote)
    }

    func testProvenanceFooterIsCarriedOver() async throws {
        let footer = NoteProvenance.footer(engine: "Parakeet", detections: [])
        let (cfg, notes, _) = try makeEnv(note: "# Meeting notes\n\nOLD" + footer)
        let result = await Pipeline.regenerate(base: "demo", options: .init(), config: cfg, deps: deps(Calls()))
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(read(notes.appendingPathComponent("demo.md")), Self.newNote + footer)
    }

    func testNoPreviousNoteStillWritesOneAndMarksDone() async throws {
        let (cfg, notes, work) = try makeEnv(note: nil)
        let result = await Pipeline.regenerate(base: "demo", options: .init(), config: cfg, deps: deps(Calls()))
        XCTAssertEqual(result.status, .done)
        XCTAssertTrue(backups(notes).isEmpty)
        let state = try DistavoState.Store(stateDir: work.appendingPathComponent(".state"), notesDir: notes)
        XCTAssertTrue(state.isDone("demo"))
    }

    func testBackupsAreNotNotesOrVariants() throws {
        XCTAssertTrue(NoteVersions.isBackupName("demo.prev-20261005-143000.md"))
        XCTAssertTrue(NoteVersions.isBackupName("demo@x-auto.prev-20261005-143000-2.md"))
        XCTAssertFalse(NoteVersions.isBackupName("demo.md"))
        XCTAssertFalse(NoteVersions.isBackupName("prev-20261005-143000.md"))
        let (cfg, notes, work) = try makeEnv()
        try "x".write(to: notes.appendingPathComponent("demo@m-auto.md"), atomically: true, encoding: .utf8)
        try "x".write(to: notes.appendingPathComponent("demo@m-auto.prev-20261005-143000.md"),
                      atomically: true, encoding: .utf8)
        _ = cfg
        let labels = RecordingVariants.list(base: "demo", notesDir: notes, workDir: work).map(\.label)
        XCTAssertEqual(labels, ["Automatic", "m-auto"])
        // The newest-note seed must not pick a backup even when it is newest.
        let backup = notes.appendingPathComponent("zzz.prev-20261005-143000.md")
        try "x".write(to: backup, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)],
                                              ofItemAtPath: backup.path)
        XCTAssertNotEqual(DistavoState.newestNote(inNotesDir: notes)?.lastPathComponent, backup.lastPathComponent)
    }

    // MARK: Prompt

    func testCustomInstructionLeavesPromptByteIdenticalWhenAbsent() {
        for style in [Prompt.Style.classic, .factsFirst] {
            let plain = Prompt.build(transcript: "T", noteOwner: "Marc", userSpeaker: "S0", style: style)
            XCTAssertEqual(plain, Prompt.build(transcript: "T", noteOwner: "Marc", userSpeaker: "S0",
                                               style: style, customInstruction: nil))
            XCTAssertEqual(plain, Prompt.build(transcript: "T", noteOwner: "Marc", userSpeaker: "S0",
                                               style: style, customInstruction: " \n "))
            let with = Prompt.build(transcript: "T", noteOwner: "Marc", userSpeaker: "S0",
                                    style: style, customInstruction: "Be brief.")
            XCTAssertTrue(with.hasPrefix(plain))
            XCTAssertTrue(with.contains("Additional instruction from the user"))
            XCTAssertTrue(with.contains("Be brief."))
        }
    }

    func testCustomInstructionIsCappedAndCountedInTheOnDeviceBudget() {
        let long = String(repeating: "x", count: 5000)
        let block = Prompt.customInstructionBlock(long)
        XCTAssertLessThan(block.count, Prompt.maxCustomInstructionChars + 300)
        let plain = EmbeddedSummaryBudget.final(contextSize: 4096, noteOwner: "M", userSpeaker: "S")
        let with = EmbeddedSummaryBudget.final(contextSize: 4096, noteOwner: "M", userSpeaker: "S",
                                               customInstruction: "Focus on risks.")
        XCTAssertEqual(plain.instructionTokens, EmbeddedSummaryBudget
            .final(contextSize: 4096, noteOwner: "M", userSpeaker: "S", customInstruction: nil).instructionTokens)
        XCTAssertGreaterThan(with.instructionTokens, plain.instructionTokens)
        // And it reaches the driver's final prompt.
        let request = SummaryRequest(transcript: "T", noteOwner: "M", userSpeaker: "S",
                                     customInstruction: "Focus on risks.")
        XCTAssertTrue(SummaryDriver.finalPrompt(request, transcript: "T").contains("Focus on risks."))
        XCTAssertFalse(SummaryDriver.finalPrompt(
            SummaryRequest(transcript: "T", noteOwner: "M", userSpeaker: "S"), transcript: "T")
            .contains("Additional instruction"))
    }

    func testRegenerateConfigAppliesChoices() {
        var cfg = Config()
        cfg.summarise.embeddedEnabled = true
        let a = Pipeline.regenerateConfig(cfg, options: .init(promptStyle: .factsFirst, model: "m", backend: "local"))
        XCTAssertEqual(a.summarise.backend, "local")
        XCTAssertEqual(a.summarise.local.model, "m")
        XCTAssertEqual(a.summarise.promptStyle, .factsFirst)
        let b = Pipeline.regenerateConfig(cfg, options: .init(model: "gemma-x", backend: "embedded"))
        XCTAssertEqual(b.summarise.embeddedModel, "gemma-x")
        XCTAssertEqual(Pipeline.regenerateConfig(cfg, options: .init()), cfg)
    }
}
