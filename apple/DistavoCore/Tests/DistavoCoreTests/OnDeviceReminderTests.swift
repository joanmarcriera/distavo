import XCTest
@testable import DistavoCore

/// #1793: the short end-of-turn reminder Apple's on-device model gets. It must stay
/// cheap (the window is 4096 tokens) and name the stock last section.
final class OnDeviceReminderTests: XCTestCase {

    func testReminderNamesTheLastStockSectionAndStaysShort() {
        XCTAssertTrue(EndOfTurnBlock.onDevice.contains("'## Suggested follow-up email'"))
        XCTAssertEqual(SummaryPostProcess.requiredHeadings(for: .classic).last, "## Suggested follow-up email")
        XCTAssertLessThan(EmbeddedSummaryTokens.estimate(EndOfTurnBlock.onDevice), 100)
        XCTAssertLessThan(EmbeddedSummaryTokens.estimate(EndOfTurnBlock.onDeviceTemplated), 60)
    }

    func testTemplatedReminderDoesNotNameTheStockEmail() {
        XCTAssertFalse(EndOfTurnBlock.onDeviceTemplated.contains("follow-up email"))
    }

    func testReminderIsCountedInTheFinalBudgetAndReachesTheFinalPrompt() {
        let plain = EmbeddedSummaryBudget.final(contextSize: 4096, noteOwner: "Anna", userSpeaker: "SPEAKER_00")
        let with = EmbeddedSummaryBudget.final(contextSize: 4096, noteOwner: "Anna", userSpeaker: "SPEAKER_00",
                                               extraInstructions: EndOfTurnBlock.onDevice)
        XCTAssertGreaterThan(with.instructionTokens, plain.instructionTokens)
        XCTAssertEqual(plain.transcriptTokens - with.transcriptTokens, with.instructionTokens - plain.instructionTokens)
        var request = SummaryRequest(transcript: "T", noteOwner: "Anna", userSpeaker: "SPEAKER_00")
        request.endOfTurnBlock = EndOfTurnBlock.onDevice
        XCTAssertTrue(SummaryDriver.finalPrompt(request, transcript: "T").hasSuffix(EndOfTurnBlock.onDevice + "\n"))
    }
}
