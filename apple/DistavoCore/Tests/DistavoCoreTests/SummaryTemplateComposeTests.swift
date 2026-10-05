import XCTest
@testable import DistavoCore

/// #2940 meets #2939 (glossary) and #2947 (custom instruction): the three compose
/// in the prompt, the on-device window guard counts all of them, and the default
/// stays byte-identical.
final class SummaryTemplateComposeTests: XCTestCase {

    private let glossary = ["Zorblax", "Quuxnet"]
    private let instruction = "Put the action items first"

    private func build(_ style: Prompt.Style, template: SummaryTemplate?, glossary: [String], instruction: String?) -> String {
        Prompt.build(transcript: "TRANSCRIPT-BODY", noteOwner: "Marc", userSpeaker: "SPEAKER_00",
                     style: style, customInstruction: instruction, glossary: glossary, template: template)
    }

    func testTemplateGlossaryAndInstructionCompose() {
        let t = SummaryTemplateCatalog.bundledTemplates[0]
        for style in [Prompt.Style.classic, .factsFirst] {
            let p = build(style, template: t, glossary: glossary, instruction: instruction)
            let g = p.range(of: "Zorblax, Quuxnet")
            let sections = p.range(of: "## Blockers")
            let transcript = p.range(of: "TRANSCRIPT-BODY")
            let extra = p.range(of: instruction)
            XCTAssertNotNil(g, "\(style) glossary"); XCTAssertNotNil(sections, "\(style) template")
            XCTAssertNotNil(extra, "\(style) instruction")
            XCTAssertLessThan(g!.lowerBound, sections!.lowerBound, "\(style): glossary in the header")
            XCTAssertLessThan(sections!.lowerBound, transcript!.lowerBound, "\(style)")
            XCTAssertGreaterThan(extra!.lowerBound, transcript!.upperBound, "\(style): instruction after the transcript")
            XCTAssertFalse(p.contains("## Technical scope"))
        }
    }

    func testDefaultIsByteIdenticalWithAllThreeOff() {
        for style in [Prompt.Style.classic, .factsFirst] {
            XCTAssertEqual(build(style, template: nil, glossary: [], instruction: nil),
                           Prompt.build(transcript: "TRANSCRIPT-BODY", noteOwner: "Marc", userSpeaker: "SPEAKER_00", style: style))
        }
        let classic = Prompt.template
            .replacingOccurrences(of: "{note_owner}", with: "Marc")
            .replacingOccurrences(of: "{user_speaker}", with: "SPEAKER_00")
            .replacingOccurrences(of: "{transcript_text}", with: "TRANSCRIPT-BODY")
        XCTAssertEqual(build(.classic, template: nil, glossary: [], instruction: nil), classic)
    }

    private func outline(sections n: Int) -> SummaryTemplate {
        let body = (0..<n).map { "## S\($0)\n" + String(repeating: "Describe what happened. ", count: 8) }.joined(separator: "\n")
        return SummaryTemplate.parse(id: "custom", name: "c", outline: body)!
    }

    /// The 75% rule must compare budgets that BOTH carry the glossary and the
    /// instruction: extras shrink both budgets by the same tokens, so a template that
    /// fits bare can fail once they are counted.
    func testWindowGuardCountsGlossaryAndInstructionOnBothSides() async throws {
        let bare = SummaryRequest(transcript: "t", noteOwner: "Marc", userSpeaker: "SPEAKER_00")
        let loaded = SummaryRequest(transcript: "t", noteOwner: "Marc", userSpeaker: "SPEAKER_00",
                                    customInstruction: String(repeating: "Focus on the budget. ", count: 45),
                                    glossary: (0..<40).map { "Termino\($0)Largo" })
        var found: SummaryTemplate?
        for n in 1...30 {
            let t = outline(sections: n)
            if SummaryDriver.templateFits(t, request: bare, contextSize: 4096),
               !SummaryDriver.templateFits(t, request: loaded, contextSize: 4096) { found = t; break }
        }
        let t = try XCTUnwrap(found, "some template fits bare but not once the extras are counted")

        // And the driver acts on it: stock sections, glossary and instruction kept.
        let gen = SummaryDriverTests.FakeGenerator(contextSize: 4096)
        _ = try await SummaryDriver.run(
            SummaryRequest(transcript: "SPEAKER_00: hi", noteOwner: "Marc", userSpeaker: "SPEAKER_00",
                           customInstruction: loaded.customInstruction, glossary: loaded.glossary, template: t),
            generator: gen)
        let prompt = try XCTUnwrap(gen.prompts.last)
        XCTAssertTrue(prompt.contains("## Technical scope"))
        XCTAssertTrue(prompt.contains("Termino0Largo"))
        XCTAssertTrue(prompt.contains("Focus on the budget."))
    }

    func testBudgetCarriesTemplateGlossaryAndInstructionTogether() {
        let t = SummaryTemplateCatalog.bundledTemplates[0]
        let plain = EmbeddedSummaryBudget.final(contextSize: 4096, noteOwner: "Marc", userSpeaker: "SPEAKER_00", template: t)
        let all = EmbeddedSummaryBudget.final(contextSize: 4096, noteOwner: "Marc", userSpeaker: "SPEAKER_00",
                                              customInstruction: instruction, glossary: glossary, template: t)
        XCTAssertGreaterThan(all.instructionTokens, plain.instructionTokens)
        let driverPrompt = SummaryDriver.finalPrompt(
            SummaryRequest(transcript: "T", noteOwner: "Marc", userSpeaker: "SPEAKER_00",
                           customInstruction: instruction, glossary: glossary, template: t), transcript: "T")
        XCTAssertTrue(driverPrompt.contains("## Blockers") && driverPrompt.contains("Zorblax") && driverPrompt.contains(instruction))
    }
}
