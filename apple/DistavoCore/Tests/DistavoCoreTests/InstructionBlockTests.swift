import XCTest
@testable import DistavoCore

/// The Regenerate "extra instruction" block (manual check 2947.8).
final class InstructionBlockTests: XCTestCase {

    /// A request for extra content needs a place to go, or it contradicts
    /// "exactly these sections" and the on-device model drops it.
    func testBlockTellsTheModelWhereExtraContentGoes() {
        let block = Prompt.customInstructionBlock("Add a closing line.")
        XCTAssertTrue(block.contains("Additional instruction from the user"))
        XCTAssertTrue(block.contains("after every section"))
        XCTAssertTrue(block.hasSuffix("<<<\nAdd a closing line.\n>>>\n"))
    }

    /// The instruction is the last thing in the prompt on both prompt styles and
    /// survives the map-reduce path's final prompt (merged notes stand in for the transcript).
    func testInstructionIsLastInSinglePassAndReducePrompts() {
        for style in [Prompt.Style.classic, .factsFirst] {
            let request = SummaryRequest(transcript: "SPEAKER_00: hi", noteOwner: "M", userSpeaker: "SPEAKER_00",
                                         style: style, customInstruction: "Add a closing line.")
            let single = SummaryDriver.finalPrompt(request, transcript: request.transcript)
            let reduce = SummaryDriver.finalPrompt(request, transcript: EmbeddedSummaryPrompt.merge(partials: ["a", "b"]))
            for prompt in [single, reduce] {
                XCTAssertTrue(prompt.hasSuffix("<<<\nAdd a closing line.\n>>>\n"), "\(style)")
            }
        }
    }

    /// No instruction, no block: the prompt for everyone else is unchanged.
    func testNoInstructionAddsNothing() {
        XCTAssertEqual(Prompt.customInstructionBlock(nil), "")
        XCTAssertEqual(Prompt.customInstructionBlock("  \n"), "")
    }
}
