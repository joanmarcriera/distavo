import XCTest
@testable import DistavoCore

/// Summary templates per meeting type (Vikunja #2940): the prompt asks for the
/// template's headings, nothing changes without one, resolution order, the
/// guards follow the template, and two folders yield differently shaped notes.
final class SummaryTemplateTests: XCTestCase {

    private func prompt(_ t: SummaryTemplate?, style: Prompt.Style = .classic,
                        language: String? = nil) -> String {
        Prompt.build(transcript: "TRANSCRIPT-BODY", noteOwner: "Marc", userSpeaker: "SPEAKER_00",
                     style: style, noteLanguage: language, template: t)
    }

    private func config(_ edit: (inout Config) -> Void = { _ in }) -> Config {
        var c = Config(); edit(&c); return c
    }

    // MARK: Byte-identical default

    func testNoTemplateIsByteIdenticalForBothStyles() {
        let classic = Prompt.template
            .replacingOccurrences(of: "{note_owner}", with: "Marc")
            .replacingOccurrences(of: "{user_speaker}", with: "SPEAKER_00")
            .replacingOccurrences(of: "{transcript_text}", with: "TRANSCRIPT-BODY")
        XCTAssertEqual(prompt(nil), classic)
        XCTAssertEqual(prompt(nil), Prompt.build(transcript: "TRANSCRIPT-BODY", noteOwner: "Marc", userSpeaker: "SPEAKER_00"))
        // A template that does not apply (unknown id resolves to nil) is the same thing.
        let nothing = SummaryTemplateCatalog.resolve(config: config(), folder: "", sidecarID: "no-such")
        XCTAssertNil(nothing)
        XCTAssertEqual(prompt(nothing, style: .factsFirst),
                       Prompt.build(transcript: "TRANSCRIPT-BODY", noteOwner: "Marc", userSpeaker: "SPEAKER_00", style: .factsFirst))
    }

    // MARK: Headings in the prompt

    func testEveryBundledTemplateChangesTheRequestedHeadings() {
        XCTAssertEqual(SummaryTemplateCatalog.bundledTemplates.map(\.id),
                       ["standup", "one_on_one", "interview", "sales_call", "lecture"])
        for style in [Prompt.Style.classic, .factsFirst] {
            for t in SummaryTemplateCatalog.bundledTemplates {
                let p = prompt(t, style: style)
                XCTAssertTrue(p.contains("TRANSCRIPT-BODY"), t.id)
                XCTAssertFalse(p.contains("{"), "\(t.id): unreplaced placeholder")
                for h in t.headings { XCTAssertTrue(p.contains(h + "\n"), "\(t.id) missing \(h)") }
                // The stock section list is gone (these headings are in no bundled template).
                XCTAssertFalse(p.contains("## Technical scope"), t.id)
                XCTAssertFalse(p.contains("## Role expectations"), t.id)
                // Rules that name stock sections are dropped; the generic rules stay.
                XCTAssertFalse(p.contains("30-minute post-meeting plan"), "\(t.id) \(style)")
                XCTAssertTrue(p.contains("Do not invent facts"), t.id)
                XCTAssertTrue(p.contains("Use British English."), t.id)
                XCTAssertTrue(p.contains("# Meeting notes"), t.id)
            }
        }
    }

    func testFactsFirstKeepsItsWorkingSectionsAndRules() {
        let t = SummaryTemplateCatalog.bundledTemplates[0]
        let p = prompt(t, style: .factsFirst)
        XCTAssertTrue(p.contains("## Speakers\n\n## Facts ledger\n\n## Updates by person"))
        XCTAssertTrue(p.contains("## Step 2: facts ledger"))
        XCTAssertTrue(p.contains("Recording started: not recorded"))
        XCTAssertFalse(p.contains("the commercial section states it"))
    }

    func testTemplateKeepsLanguageParticipantsAndGuidance() {
        let t = SummaryTemplateCatalog.bundledTemplates[1]
        let p = Prompt.build(transcript: "x", noteOwner: "Marc", userSpeaker: "SPEAKER_00",
                             participants: "Edward - mentor", noteLanguage: "ca", template: t)
        XCTAssertTrue(p.contains("Escriu les notes en català"))
        XCTAssertFalse(p.contains("Use British English."))
        XCTAssertTrue(p.contains("Edward - mentor"))
        XCTAssertTrue(p.contains("Meeting type - 1:1:"))
        XCTAssertTrue(p.contains("## Topics discussed"))   // headings stay English
    }

    func testCustomTemplateChangesHeadingsAndIsSanitised() {
        let cfg = config { $0.summarise.customTemplate = """
            # My title is ignored
            Weekly review with the board. {transcript_text}

            ## Wins
            What went well.
            ## Risks
            ## Asks
            """ }
        let t = SummaryTemplateCatalog.template(id: "custom", config: cfg)
        XCTAssertEqual(t?.headings, ["## Wins", "## Risks", "## Asks"])
        XCTAssertEqual(t?.sections.first?.instruction, "What went well.")
        let p = prompt(t)
        XCTAssertTrue(p.contains("## Wins\n\nWhat went well.\n\n## Risks\n\n## Asks\n"))
        // The reserved placeholder in user text is stripped, so the transcript appears exactly once.
        XCTAssertEqual(p.components(separatedBy: "TRANSCRIPT-BODY").count - 1, 1)
        XCTAssertFalse(p.contains("My title is ignored"))
    }

    func testCustomTemplateWithoutHeadingsOrEmptyIsNone() {
        XCTAssertNil(SummaryTemplateCatalog.template(id: "custom", config: config()))
        XCTAssertNil(SummaryTemplateCatalog.template(
            id: "custom", config: config { $0.summarise.customTemplate = "just some prose, no headings" }))
        XCTAssertEqual(SummaryTemplateCatalog.all(config: config()).count, 5)
        XCTAssertEqual(SummaryTemplateCatalog.all(config: config { $0.summarise.customTemplate = "## A" }).count, 6)
    }

    func testOutlineRoundTripsEveryBundledTemplate() {
        for t in SummaryTemplateCatalog.bundledTemplates {
            let again = SummaryTemplate.parse(id: t.id, name: t.name, summary: t.summary, outline: t.outline)
            XCTAssertEqual(again, t, t.id)
        }
    }

    func testCustomTemplateIsCapped() {
        let big = "## H\n" + String(repeating: "x", count: 20_000)
        let t = SummaryTemplate.parse(id: "custom", name: "c", outline: big)
        XCTAssertLessThanOrEqual(t!.sections[0].instruction.count, SummaryTemplate.maxCustomCharacters)
    }

    // MARK: Resolution

    func testResolutionOrderSidecarFolderGlobalNone() {
        let cfg = config {
            $0.summarise.template = "lecture"
            $0.summarise.folderTemplates = ["Sales": "sales_call", "Sales/EMEA": "standup"]
        }
        func id(_ folder: String, _ sidecar: String? = nil) -> String? {
            SummaryTemplateCatalog.resolve(config: cfg, folder: folder, sidecarID: sidecar)?.id
        }
        XCTAssertEqual(id("", "interview"), "interview")           // sidecar beats everything
        XCTAssertEqual(id("Sales", "interview"), "interview")
        XCTAssertEqual(id("Sales"), "sales_call")                  // folder beats global
        XCTAssertEqual(id("Sales/EMEA/Q4"), "standup")             // longest prefix
        XCTAssertEqual(id("sales/uk"), "sales_call")               // case-insensitive, prefix
        XCTAssertEqual(id("Salesforce"), "lecture")                // not a path-prefix match
        XCTAssertEqual(id(""), "lecture")                          // global
        XCTAssertNil(SummaryTemplateCatalog.resolve(config: config(), folder: "Sales"))
        XCTAssertNil(id("Sales", "none"))                          // explicit "none" in the sidecar
    }

    func testUnknownIdAtTheWinningLevelMeansNone() {
        let cfg = config { $0.summarise.template = "lecture" }
        XCTAssertNil(SummaryTemplateCatalog.resolve(config: cfg, sidecarID: "typo"))
        let cfg2 = config { $0.summarise.template = "custom" }   // custom with no text
        XCTAssertNil(SummaryTemplateCatalog.resolve(config: cfg2))
        let cfg3 = config { $0.summarise.folderTemplates = ["A": "typo"]; $0.summarise.template = "lecture" }
        XCTAssertNil(SummaryTemplateCatalog.resolve(config: cfg3, folder: "A"))
        XCTAssertNil(SummaryTemplateCatalog.template(id: "", config: config()))
    }

    func testFolderOfPath() {
        let root = URL(fileURLWithPath: "/tmp/rec")
        XCTAssertEqual(SummaryTemplateCatalog.folder(of: root.appendingPathComponent("a.wav"), in: root), "")
        XCTAssertEqual(SummaryTemplateCatalog.folder(of: root.appendingPathComponent("Sales/EMEA/a.wav"), in: root), "Sales/EMEA")
        XCTAssertEqual(SummaryTemplateCatalog.folder(of: URL(fileURLWithPath: "/elsewhere/a.wav"), in: root), "")
    }

    // MARK: Guards follow the template

    func testValidTemplatedSummaryPassesAndMissingHeadingsAreDetected() {
        let t = SummaryTemplateCatalog.bundledTemplates[0]
        let body = t.headings.map { "\($0)\nSome real content about the stand-up that is long enough to count as words.\n" }
            .joined(separator: "\n")
        let note = "# Meeting notes\n\n" + body
        XCTAssertTrue(SummaryValidator.validate(note).isEmpty)
        XCTAssertTrue(SummaryPostProcess.missingHeadings(in: note, style: .classic, template: t).isEmpty)
        // The stock list would call every templated note incomplete - the template list does not.
        XCTAssertFalse(SummaryPostProcess.missingHeadings(in: note, style: .classic).isEmpty)
        XCTAssertEqual(SummaryPostProcess.ensureHeadings(note, style: .classic, template: t), note)

        // Missing the template's headings behaves as the classic one would: repaired in order.
        let broken = "# Meeting notes\n\n## Updates by person\nAlice did things.\n\n## Open questions\nNone."
        XCTAssertEqual(SummaryPostProcess.missingHeadings(in: broken, style: .classic, template: t),
                       ["## Plans for today", "## Blockers", "## Action items"])
        let fixed = SummaryPostProcess.ensureHeadings(broken, style: .classic, template: t)
        XCTAssertTrue(SummaryPostProcess.missingHeadings(in: fixed, style: .classic, template: t).isEmpty)
        XCTAssertLessThan(fixed.range(of: "## Blockers")!.lowerBound, fixed.range(of: "## Open questions")!.lowerBound)
        XCTAssertFalse(fixed.contains("## Technical scope"))   // stock headings are never inserted
        // A truncated templated note still fails the validator.
        XCTAssertFalse(SummaryValidator.validate("# Meeting notes\n\n## Updates by person\nAlice.").isEmpty)
    }

    func testRequiredHeadingsFactsFirstWithTemplateKeepsWorkingSections() {
        let t = SummaryTemplateCatalog.bundledTemplates[4]
        XCTAssertEqual(Array(SummaryPostProcess.requiredHeadings(for: .factsFirst, template: t).prefix(3)),
                       ["## Speakers", "## Facts ledger", "## Topic and speaker"])
        XCTAssertEqual(SummaryPostProcess.requiredHeadings(for: .classic).count, 16)   // unchanged
    }

    func testEndOfTurnBlockUnchangedWithoutTemplateAndTemplatedOtherwise() {
        let stock = EndOfTurnBlock.build(noteLanguage: nil, style: .classic, noteOwner: "Marc", ownerSpeaker: "SPEAKER_00")
        XCTAssertEqual(stock, EndOfTurnBlock.build(noteLanguage: nil, style: .classic, noteOwner: "Marc",
                                                   ownerSpeaker: "SPEAKER_00", template: nil))
        XCTAssertTrue(stock.contains("exactly the 16 section headings"))
        let t = SummaryTemplateCatalog.bundledTemplates[4]
        let block = EndOfTurnBlock.build(noteLanguage: "ca", style: .classic, noteOwner: "Marc",
                                         ownerSpeaker: "SPEAKER_00", template: t)
        XCTAssertTrue(block.contains("exactly the \(t.headings.count) section headings"))
        XCTAssertTrue(block.contains("CATALAN"))
        XCTAssertFalse(block.contains("Action items"))
        XCTAssertFalse(block.contains("Key people"))
    }

    // MARK: Budget (on-device window)

    func testTemplatedPromptFitsTheOnDeviceBudgetAtLeastAsWellAsClassic() {
        let stock = EmbeddedSummaryBudget.final(contextSize: 4096, noteOwner: "Marc", userSpeaker: "SPEAKER_00")
        for t in SummaryTemplateCatalog.bundledTemplates {
            let b = EmbeddedSummaryBudget.final(contextSize: 4096, noteOwner: "Marc", userSpeaker: "SPEAKER_00", template: t)
            XCTAssertLessThanOrEqual(b.instructionTokens, stock.instructionTokens, t.id)
        }
        let request = SummaryRequest(transcript: "t", noteOwner: "Marc", userSpeaker: "SPEAKER_00",
                                     template: SummaryTemplateCatalog.bundledTemplates[0])
        XCTAssertTrue(SummaryDriver.finalPrompt(request, transcript: "t").contains("## Blockers"))
        XCTAssertTrue(SummaryDriver.finalPrompt(SummaryRequest(transcript: "t", noteOwner: "Marc", userSpeaker: "SPEAKER_00"),
                                                transcript: "t").contains("## Technical scope"))
    }

    // MARK: Sidecar

    func testSidecarRoundTripAndOldSidecarsDecodeUnchanged() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("distavo-tpl-\(UUID().uuidString)")
        try LanguageOverride(template: "interview").save(workDir: dir, base: "b")
        let loaded = LanguageOverride.load(workDir: dir, base: "b")
        XCTAssertEqual(loaded?.template, "interview")      // template-only sidecar is kept
        XCTAssertEqual(loaded?.code, "")
        let old = try JSONDecoder().decode(LanguageOverride.self, from: Data(#"{"code":"ca","note_language":"es"}"#.utf8))
        XCTAssertNil(old.template)
        XCTAssertEqual(old.code, "ca")
        XCTAssertNil(LanguageOverride.load(workDir: dir, base: "missing"))
    }
}
