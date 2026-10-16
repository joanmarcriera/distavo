import XCTest
@testable import DistavoCore

/// Vikunja #3578: the default facts-first prompt once carried examples from one UK
/// contracting / HPC call (IR35, day rates, Slurm, Bull, EMBL-EBI, "16 September"). An
/// 8B model copied them into the facts ledger of unrelated meetings. The default prompt
/// must hold none of them; the rules live in the opt-in "UK contracting" template.
final class PromptNoDomainExamplesTests: XCTestCase {

    private static let banned = ["IR35", "IR-35", "Slurm", "EMBL", "Bull", "Buell", "Lustre", "HGX",
                                 "GB300", "Roche", "16 September", "9 September", "limited company", "day rate"]

    private func prompt(_ t: SummaryTemplate? = nil, style: Prompt.Style = .factsFirst) -> String {
        Prompt.build(transcript: "TRANSCRIPT-BODY", noteOwner: "Marc", userSpeaker: "SPEAKER_00",
                     style: style, meetingDate: Date(timeIntervalSince1970: 1_790_000_000), template: t)
    }

    func testDefaultFactsFirstPromptHasNoDomainExamples() {
        for style in [Prompt.Style.factsFirst, .classic] {
            let p = prompt(style: style)
            for word in Self.banned { XCTAssertFalse(p.contains(word), "\(style) default prompt contains \(word)") }
        }
        XCTAssertFalse(Prompt.factsFirstTemplate.contains("IR35"))
    }

    func testDefaultPromptTellsTheModelToCopyOnlyWhatWasSaid() {
        XCTAssertTrue(prompt().contains("Only list a fact if you can copy its words from the transcript"))
    }

    func testEveryBundledTemplateExceptUKContractingStaysClean() {
        for t in SummaryTemplateCatalog.bundledTemplates where t.id != SummaryTemplateCatalog.ukContractingID {
            let p = prompt(t)
            for word in Self.banned { XCTAssertFalse(p.contains(word), "\(t.id) contains \(word)") }
        }
    }

    func testUKContractingTemplateIsOptInAndBringsTheRulesBack() throws {
        let t = try XCTUnwrap(SummaryTemplateCatalog.template(id: SummaryTemplateCatalog.ukContractingID, config: Config()))
        let p = prompt(t)
        XCTAssertTrue(p.contains("IR35"))
        XCTAssertTrue(p.contains("slum, slums, slurp -> Slurm"))
        XCTAssertTrue(p.contains("own limited company"))
        XCTAssertFalse(p.contains("{"), "unreplaced placeholder")
        // The rules sit inside the ledger rules / note rules, in order.
        let ir = try XCTUnwrap(p.range(of: "IR35"))
        let step3 = try XCTUnwrap(p.range(of: "## Step 3"))
        XCTAssertTrue(ir.lowerBound < step3.lowerBound)
        // Not the default: nothing resolves to it unless named.
        XCTAssertNil(SummaryTemplateCatalog.resolve(config: Config()))
    }
}
