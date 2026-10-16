import XCTest
@testable import DistavoCore

/// Vikunja #3582: the summary template is picked per recording; a stale global "interview" no longer
/// turns a consultancy call into "Candidate and role".
final class TemplateAutoPickTests: XCTestCase {

    private func config(_ edit: (inout Config) -> Void = { _ in }) -> Config { var c = Config(); edit(&c); return c }

    func testConsultantParticipantsPickConsultancy() {
        let who = "The note owner (me): consultor. Other participants: Anna, CEO; Bernat, IT lead; Carla, CFO"
        let pick = TemplateAutoPick.pick(participants: who, transcript: "")
        XCTAssertEqual(pick?.id, "consultancy")
        XCTAssertTrue(pick?.reason.contains("consultor") == true, pick?.reason ?? "")
    }

    func testRecruiterAndInterviewPickInterview() {
        XCTAssertEqual(TemplateAutoPick.pick(participants: "Other participants: Sam, recruiter at a client; interview for a CTO role", transcript: "")?.id, "interview")
        XCTAssertEqual(TemplateAutoPick.pick(participants: "Other participants: a head-hunter", transcript: "")?.id, "interview")
    }

    func testTranscriptStartCanDecideWhenNothingWasSaid() {
        XCTAssertEqual(TemplateAutoPick.pick(participants: nil, transcript: "Welcome to the daily stand-up, no blockers today? scrum")?.id, "standup")
    }

    func testUnclearOrTiedPicksNothing() {
        XCTAssertNil(TemplateAutoPick.pick(participants: "Other participants: Anna, Bernat", transcript: "Bon dia, com va tot?"))
        XCTAssertNil(TemplateAutoPick.pick(participants: nil, transcript: ""))
        // consultant (3) and candidate (3): a tie is not a decision.
        XCTAssertNil(TemplateAutoPick.pick(participants: "a consultant and a candidate", transcript: ""))
    }

    func testWholeWordsOnly() {
        XCTAssertNil(TemplateAutoPick.pick(participants: "Other participants: Oceon Ltd, Discoveryland", transcript: ""))
    }

    // MARK: Resolver order, with auto

    func testResolverOrderSidecarFolderGlobalIncludingAuto() {
        let who = "Consultor; the client CEO"
        let c = config { $0.summarise.template = "interview"; $0.summarise.folderTemplates = ["Clients": "auto"] }
        // sidecar beats folder beats global
        XCTAssertEqual(SummaryTemplateCatalog.resolve(config: c, folder: "Clients", sidecarID: "lecture", participants: who)?.id, "lecture")
        // folder says auto: picked from content, not the global interview
        let viaFolder = SummaryTemplateCatalog.resolveWithReason(config: c, folder: "Clients", participants: who)
        XCTAssertEqual(viaFolder.template?.id, "consultancy")
        XCTAssertEqual(viaFolder.note, "Template: Consultancy / client meeting (auto, matched consultor, ceo, client)")
        // no folder rule: the global interview applies, as named
        XCTAssertEqual(SummaryTemplateCatalog.resolve(config: c, folder: "", participants: who)?.id, "interview")
        // sidecar auto beats the stale global
        XCTAssertEqual(SummaryTemplateCatalog.resolve(config: c, folder: "", sidecarID: "auto", participants: who)?.id, "consultancy")
        // auto with nothing to go on = standard note; none stays none
        XCTAssertNil(SummaryTemplateCatalog.resolve(config: config { $0.summarise.template = "auto" }, participants: "Anna"))
        XCTAssertNil(SummaryTemplateCatalog.resolve(config: c, sidecarID: "none", participants: who))
        XCTAssertNil(SummaryTemplateCatalog.template(id: "auto", config: c), "auto is not a template itself")
    }

    func testConsultancyTemplateHasNoCandidateSections() throws {
        let t = try XCTUnwrap(SummaryTemplateCatalog.template(id: "consultancy", config: Config()))
        XCTAssertEqual(t.headings, ["## Context", "## Findings", "## Recommendations", "## Decisions", "## Actions", "## Risks and open questions"])
        let p = Prompt.build(transcript: "T", noteOwner: "Marc", userSpeaker: "u", style: .factsFirst, template: t)
        XCTAssertFalse(p.contains("## Candidate and role"))
        XCTAssertTrue(p.contains("## Findings\n"))
    }

    func testFreshInstallsDefaultToAutoAndExistingConfigsAreUntouched() throws {
        XCTAssertEqual(Config.recommendedForThisMac(embeddedSupported: false, memoryBytes: 16 << 30).summarise.template, "auto")
        XCTAssertEqual(Config().summarise.template, "", "no global template without the fresh-install default")
        XCTAssertEqual(SettingsDefaults.templateLabel(config { $0.summarise.template = "auto" }),
                       "Default from Settings (Auto, from the participants)")
    }

    // MARK: Footer

    func testPipelineFooterNamesTheAutoChoice() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("distavo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        var cfg = Config()
        cfg.recordingsDir = dir.appendingPathComponent("rec").path
        cfg.notesDir = dir.appendingPathComponent("notes").path
        cfg.workDir = dir.appendingPathComponent("work").path
        cfg.summarise.template = "auto"
        cfg.summarise.promptStyle = .classic
        for d in [cfg.recordingsDir, cfg.notesDir, cfg.workDir] { try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true) }
        let input = URL(fileURLWithPath: cfg.recordingsDir).appendingPathComponent("demo.opus")
        try Data(repeating: 1, count: 64).write(to: input)
        try SpeakerHints(count: nil, participants: "Other participants: Anna, CEO of the client; I am the consultant")
            .save(workDir: URL(fileURLWithPath: cfg.workDir), base: "demo")
        let seen = LockedBox<String?>(nil)
        let deps = PipelineDeps(
            convertToWav: { _, dest in
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data([0]).write(to: dest)
            },
            transcribe: { _, _ in ["segments": [["speaker": "SPEAKER_00", "text": "hello world"]]] },
            ollamaReachable: { _ in true },
            summarise: { _, _, _, context in seen.set(context.template?.id); return PipelineTests.validNote },
            audioDurationSeconds: { _ in 60 })
        let r = await Pipeline.processOne(path: input, config: cfg, deps: deps, stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(r.status, .done, r.message)
        XCTAssertEqual(seen.value ?? nil, "consultancy")
        let note = try String(contentsOf: try XCTUnwrap(r.notePath))
        XCTAssertTrue(note.contains("_Summary: Template: Consultancy / client meeting (auto, matched consultant, ceo, client)."), note)
    }
}

private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock(); private var v: T
    init(_ v: T) { self.v = v }
    func set(_ x: T) { lock.lock(); v = x; lock.unlock() }
    var value: T { lock.lock(); defer { lock.unlock() }; return v }
}
