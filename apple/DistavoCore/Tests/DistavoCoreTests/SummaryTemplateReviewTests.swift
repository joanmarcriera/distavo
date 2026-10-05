import XCTest
@testable import DistavoCore

/// Review fixes for #2940: the on-device window guard, placeholder stripping,
/// facts-first working-section de-duplication, and regenerate-with-template.
final class SummaryTemplateReviewTests: XCTestCase {

    private func fake(_ context: Int) -> SummaryDriverTests.FakeGenerator {
        SummaryDriverTests.FakeGenerator(contextSize: context)
    }

    /// A dense custom template of about 4000 characters (many short sections).
    private var denseOutline: String {
        var out = ""
        var n = 0
        while out.count < 3950 {
            out += "## Section \(n)\n" + String(repeating: "Describe in detail what happened here. ", count: 10) + "\n"
            n += 1
        }
        return out
    }

    // MARK: 1. On-device window

    func testHugeCustomTemplateDegradesToStockNoteOnTheSmallWindow() async throws {
        let t = SummaryTemplate.parse(id: "custom", name: "Custom", outline: denseOutline)!
        let transcript = "SPEAKER_00: we agreed to ship the migration on Friday."
        let gen = fake(4096)
        let request = SummaryRequest(transcript: transcript, noteOwner: "Marc", userSpeaker: "SPEAKER_00", template: t)
        let notes = ProgressLog()
        let out = try await SummaryDriver.run(request, generator: gen, onProgress: { notes.add($0) })
        XCTAssertFalse(out.isEmpty)
        let prompt = try XCTUnwrap(gen.prompts.last)
        XCTAssertTrue(prompt.contains("## Technical scope"), "stock sections")
        XCTAssertFalse(prompt.contains("## Section 0"))
        XCTAssertTrue(prompt.contains(transcript), "non-empty transcript in the prompt")
        XCTAssertTrue(notes.all.contains { $0.contains("template is too long") })
    }

    func testBundledTemplatesAreKeptOnTheSmallWindow() async throws {
        let gen = fake(4096)
        let t = SummaryTemplateCatalog.bundledTemplates[0]
        _ = try await SummaryDriver.run(
            SummaryRequest(transcript: "SPEAKER_00: hi", noteOwner: "Marc", userSpeaker: "SPEAKER_00", template: t),
            generator: gen)
        XCTAssertTrue(gen.prompts.last!.contains("## Blockers"))
    }

    func testDegradedRunRebuildsTheEndOfTurnBlockForTheStockSections() async throws {
        let t = SummaryTemplate.parse(id: "custom", name: "Custom", outline: denseOutline)!
        let gen = fake(4096)
        let block = EndOfTurnBlock.build(noteLanguage: nil, style: .classic, noteOwner: "Marc",
                                         ownerSpeaker: "SPEAKER_00", template: t)
        _ = try await SummaryDriver.run(
            SummaryRequest(transcript: "SPEAKER_00: hi", noteOwner: "Marc", userSpeaker: "SPEAKER_00",
                           endOfTurnBlock: block, template: t), generator: gen)
        XCTAssertTrue(gen.prompts.last!.contains("exactly the 16 section headings"))
    }

    func testReduceToFitRefusesAZeroBudgetInsteadOfAnEmptyTranscript() async {
        let gen = fake(1200)    // the final prompt alone fills this window
        let request = SummaryRequest(transcript: "x", noteOwner: "Marc", userSpeaker: "SPEAKER_00")
        do {
            _ = try await SummaryDriver.reduceToFit(partials: ["a", "b"], request: request, generator: gen,
                                                    onProgress: { _ in })
            XCTFail("expected contextTooSmall")
        } catch let e as SummaryDriverError {
            guard case .contextTooSmall = e else { return XCTFail("\(e)") }
        } catch { XCTFail("\(error)") }
    }

    // MARK: 2. Placeholder reassembly

    func testBracesCannotReassembleAPlaceholder() {
        let t = SummaryTemplate.parse(id: "custom", name: "c", outline: "## A\n{transc{note_owner}ript_text}")!
        let p = Prompt.build(transcript: "TRANSCRIPT-BODY", noteOwner: "Marc", userSpeaker: "SPEAKER_00", template: t)
        XCTAssertEqual(p.components(separatedBy: "TRANSCRIPT-BODY").count - 1, 1)
        XCTAssertFalse(t.sections[0].instruction.contains("{"))
    }

    // MARK: 3. Facts-first working sections

    func testTemplateListingWorkingSectionsDoesNotDuplicateThem() {
        let t = SummaryTemplate.parse(id: "custom", name: "c", outline: "## speakers\n## Facts Ledger\n## Wins\n## wins\n## Risks")!
        XCTAssertEqual(t.headings, ["## speakers", "## Facts Ledger", "## Wins", "## Risks"])   // duplicate "wins" dropped
        let p = Prompt.build(transcript: "T", noteOwner: "Marc", userSpeaker: "SPEAKER_00", style: .factsFirst, template: t)
        XCTAssertEqual(p.components(separatedBy: "\n## Speakers\n").count - 1, 1)
        XCTAssertFalse(p.contains("## speakers"))
        XCTAssertEqual(p.lowercased().components(separatedBy: "\n## facts ledger\n").count - 1, 1)
        XCTAssertEqual(SummaryPostProcess.requiredHeadings(for: .factsFirst, template: t),
                       ["## Speakers", "## Facts ledger", "## Wins", "## Risks"])
        let fixed = SummaryPostProcess.ensureHeadings("# Meeting notes\n\n## Wins\nx", style: .factsFirst, template: t)
        XCTAssertEqual(fixed.components(separatedBy: "## Speakers").count - 1, 1)
        XCTAssertEqual(fixed.components(separatedBy: "## Facts ledger").count - 1, 1)
        XCTAssertLessThan(fixed.range(of: "## Speakers")!.lowerBound, fixed.range(of: "## Wins")!.lowerBound)
    }

    // MARK: 5. Regenerate with a template

    private func env() throws -> (Config, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("distavo-regtpl-\(UUID().uuidString)")
        var cfg = Config()
        cfg.recordingsDir = root.appendingPathComponent("recordings").path
        cfg.notesDir = root.appendingPathComponent("notes").path
        cfg.workDir = root.appendingPathComponent("work").path
        let work = URL(fileURLWithPath: cfg.workDir)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try "SPEAKER_00: hello there".write(to: Pipeline.cachedTranscriptURL(workDir: work, base: "demo"),
                                            atomically: true, encoding: .utf8)
        return (cfg, work)
    }

    private func regenerate(_ cfg: Config, _ options: RegenerateOptions, sourcePath: URL? = nil) async -> NoteContext? {
        let box = ContextBox()
        let deps = PipelineDeps(
            convertToWav: { _, _ in }, transcribe: { _, _ in [:] }, ollamaReachable: { _ in true },
            summarise: { _, _, _, context in box.set(context); return PipelineTests.validNote })
        _ = await Pipeline.regenerate(base: "demo", options: options, config: cfg, deps: deps, sourcePath: sourcePath)
        return box.value
    }

    func testRegenerateAppliesTheChosenTemplate() async throws {
        let (cfg, _) = try env()
        let ctx = await regenerate(cfg, RegenerateOptions(templateID: "lecture"))
        XCTAssertEqual(ctx?.template?.id, "lecture")
        XCTAssertTrue(ctx!.prompt(transcript: "T").contains("## Key concepts"))
    }

    func testRegenerateWithoutAChoiceKeepsTheNormalResolution() async throws {
        var (cfg, work) = try env()
        cfg.summarise.template = "standup"
        let plain = await regenerate(cfg, RegenerateOptions())
        XCTAssertEqual(plain?.template?.id, "standup")
        // An unknown id behaves like no choice.
        let typo = await regenerate(cfg, RegenerateOptions(templateID: "typo"))
        XCTAssertEqual(typo?.template?.id, "standup")
        // A per-recording sidecar and a folder rule are part of "normal".
        cfg.summarise.folderTemplates = ["Sales": "sales_call"]
        let source = URL(fileURLWithPath: cfg.recordingsDir).appendingPathComponent("Sales/demo.opus")
        let folder = await regenerate(cfg, RegenerateOptions(), sourcePath: source)
        XCTAssertEqual(folder?.template?.id, "sales_call")
        try LanguageOverride(template: "interview").save(workDir: work, base: "demo")
        let sidecar = await regenerate(cfg, RegenerateOptions(), sourcePath: source)
        XCTAssertEqual(sidecar?.template?.id, "interview")
    }

    func testRegenerateNoneForcesStandardNotes() async throws {
        var (cfg, _) = try env()
        cfg.summarise.template = "standup"
        let ctx = await regenerate(cfg, RegenerateOptions(templateID: "none"))
        XCTAssertNil(ctx?.template)
        XCTAssertTrue(ctx!.prompt(transcript: "T").contains("## Technical scope"))
    }

    func testRegenerateCustomUsesTheCustomText() async throws {
        var (cfg, _) = try env()
        cfg.summarise.customTemplate = "## Wins\n## Risks"
        let ctx = await regenerate(cfg, RegenerateOptions(templateID: "custom"))
        XCTAssertEqual(ctx?.template?.headings, ["## Wins", "## Risks"])
    }
}

private final class ContextBox: @unchecked Sendable {
    private let lock = NSLock()
    private var ctx: NoteContext?
    func set(_ c: NoteContext) { lock.lock(); ctx = c; lock.unlock() }
    var value: NoteContext? { lock.lock(); defer { lock.unlock() }; return ctx }
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
}
