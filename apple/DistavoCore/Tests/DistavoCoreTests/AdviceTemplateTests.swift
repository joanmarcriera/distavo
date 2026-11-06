import XCTest
@testable import DistavoCore

/// Vikunja #6355: an "Advice call" template (accountant, lawyer, financial adviser) that keeps the
/// advice and the numbers, not only the tasks. All fixtures are synthetic (invented adviser, rates and
/// amounts); no real recording or transcript is used.
final class AdviceTemplateTests: XCTestCase {

    private let id = SummaryTemplateCatalog.adviceCallID

    private func template() throws -> SummaryTemplate {
        try XCTUnwrap(SummaryTemplateCatalog.template(id: id, config: Config()))
    }

    private func prompt(_ t: SummaryTemplate?, style: Prompt.Style) -> String {
        Prompt.build(transcript: "TRANSCRIPT-BODY", noteOwner: "Owner", userSpeaker: "SPEAKER_00",
                     style: style, template: t)
    }

    func testIsBundledWithTheFiveSectionsInOrder() throws {
        XCTAssertEqual(id, "advice_call")
        XCTAssertEqual(try template().headings,
                       ["## Advice given", "## Figures and thresholds", "## Actions by party",
                        "## Questions to take back", "## Next meeting"])
    }

    func testAdviceSectionAsksForRuleNumberConditionSpeakerAndTimestamp() throws {
        let advice = try XCTUnwrap(try template().sections.first { $0.heading == "## Advice given" })
        for word in ["rule", "number", "condition", "who said it", "timestamp"] {
            XCTAssertTrue(advice.instruction.lowercased().contains(word), "missing \(word)")
        }
    }

    func testFiguresSectionIsATableAndAttributesTheAdviser() throws {
        let figures = try XCTUnwrap(try template().sections.first { $0.heading == "## Figures and thresholds" })
        XCTAssertTrue(figures.instruction.contains("| Figure |"))
        // The ledger credited the owner with figures the adviser gave: attribution must be explicit.
        XCTAssertTrue(try template().guidance.lowercased().contains("never credit"))
    }

    func testPromptsCarryTheSectionsInBothStyles() throws {
        let t = try template()
        for style in [Prompt.Style.classic, .factsFirst] {
            let p = prompt(t, style: style)
            XCTAssertTrue(p.contains("TRANSCRIPT-BODY"))
            XCTAssertFalse(p.contains("{"), "unreplaced placeholder")
            for h in t.headings { XCTAssertTrue(p.contains(h + "\n"), "\(style) missing \(h)") }
            XCTAssertFalse(p.contains("## Technical scope"))
            XCTAssertFalse(p.contains("30-minute post-meeting plan"))
        }
    }

    func testStaysFreeOfDomainExamplesFromTheDefaultPrompt() throws {
        let p = prompt(try template(), style: .factsFirst)
        XCTAssertFalse(p.contains("IR35"))
        XCTAssertFalse(p.contains("Slurm"))
    }

    // MARK: Auto-pick (synthetic participants sheets)

    func testAccountantSolicitorAndFinancialAdviserPickAdviceCall() {
        for who in ["Other participants: Dana Example, accountant",
                    "Other participants: Lee Sample, solicitor",
                    "Other participants: R. Test, lawyer at a firm",
                    "Other participants: Sam Placeholder, IFA",
                    "Other participants: Pat Invented, financial adviser"] {
            XCTAssertEqual(TemplateAutoPick.pick(participants: who, transcript: "")?.id, id, who)
        }
    }

    func testAdviceCallBeatsConsultancyWhenBothWordsAppear() {
        // "adviser" alone is a consultancy word; the profession must win over it.
        XCTAssertEqual(TemplateAutoPick.pick(participants: "tax adviser and accountant", transcript: "")?.id, id)
    }

    func testConsultancyAndRecruiterPicksAreUnchanged() {
        XCTAssertEqual(TemplateAutoPick.pick(participants: "consultor; client CEO", transcript: "")?.id, "consultancy")
        XCTAssertEqual(TemplateAutoPick.pick(participants: "a recruiter", transcript: "")?.id, "interview")
    }

    func testSyntheticTranscriptStartCanPickIt() {
        let t = "Thanks for taking the call. As your accountant I should say the dividend allowance question depends on the structure."
        XCTAssertEqual(TemplateAutoPick.pick(participants: nil, transcript: t)?.id, id)
    }

    func testAutoResolvesToTheTemplateWithAFooterReason() {
        var c = Config(); c.summarise.template = "auto"
        let r = SummaryTemplateCatalog.resolveWithReason(config: c, participants: "Dana Example, accountant")
        XCTAssertEqual(r.template?.id, id)
        XCTAssertEqual(r.note, "Template: Advice call (auto, matched accountant)")
    }
}
