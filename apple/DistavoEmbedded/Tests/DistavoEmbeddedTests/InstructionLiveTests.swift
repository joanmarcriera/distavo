import XCTest
import DistavoCore
@testable import DistavoEmbedded

/// Does Apple's on-device model act on a Regenerate "extra instruction" that asks
/// for something outside the fixed section list (manual check 2947.8)? Real
/// model, so gated like the other live tests:
///
///   DISTAVO_SUMMARY_LIVE=1 swift test --filter InstructionLiveTests
final class InstructionLiveTests: XCTestCase {
    private var live: Bool { ProcessInfo.processInfo.environment["DISTAVO_SUMMARY_LIVE"] == "1" }

    private let transcript = """
    SPEAKER_00: Thanks for joining. Let's talk about the GPU cluster.
    SPEAKER_01: Sure, what's the budget?
    SPEAKER_00: Around fifty thousand, and it needs approving this quarter.
    SPEAKER_01: I'll draft the procurement request and send it to finance on Thursday.
    SPEAKER_00: Good. I'll review the vendor quotes meanwhile.
    """

    func testInstructionAskingForAnExtraLineIsFollowed() async throws {
        try XCTSkipUnless(live, "set DISTAVO_SUMMARY_LIVE=1 to run")
        try XCTSkipUnless(EmbeddedSummariser.isAvailable, "Apple Intelligence unavailable")
        let runs = Int(ProcessInfo.processInfo.environment["DISTAVO_INSTRUCTION_RUNS"] ?? "") ?? 3
        var followed = 0
        for i in 1...runs {
            let note = try await EmbeddedSummariser.summarise(
                transcript: transcript, noteOwner: "Marc", userSpeaker: "SPEAKER_00",
                customInstruction: "At the very bottom of the note add this line: Don Quijote, by Cervantes")
            let ok = note.localizedCaseInsensitiveContains("Quijote")
            if ok { followed += 1 }
            print("INSTRUCTION-LIVE run \(i): followed=\(ok) tail=\(note.suffix(160).replacingOccurrences(of: "\n", with: " ⏎ "))")
            XCTAssertEqual(SummaryValidator.validate(note), [], "note failed the validator")
        }
        print("INSTRUCTION-LIVE followed \(followed)/\(runs)")
        XCTAssertEqual(followed, runs, "the on-device model ignored the instruction in \(runs - followed) of \(runs) runs")
    }
}
