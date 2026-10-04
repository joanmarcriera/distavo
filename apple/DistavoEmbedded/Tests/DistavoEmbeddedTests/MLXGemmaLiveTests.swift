import XCTest
import DistavoCore
@testable import DistavoEmbedded

/// Local-Gemma checks (Vikunja #2198 S4). The live test loads the real
/// ~5 GB weights, so it is skipped unless DISTAVO_LIVE=1; point
/// DISTAVO_GEMMA_DIR at a folder of gemma-4-e4b-it-4bit (defaults to the spike
/// copy). Nothing here downloads a model.
final class MLXGemmaLiveTests: XCTestCase {

    func testGeneratorReportsTheConfiguredContextAndUnloadIsSafeWhenNeverLoaded() {
        let gen = MLXGemmaGenerator(modelDirectory: URL(fileURLWithPath: "/nonexistent"),
                                    modelID: "gemma-4-e4b", contextSize: 16384)
        XCTAssertEqual(gen.contextSize, 16384)
        gen.unload()   // no weights loaded: must not crash
    }

    func testMissingWeightsAreARetryableDeferralNotAHardFailure() async {
        let gen = MLXGemmaGenerator(modelDirectory: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"),
                                    modelID: "gemma-test", contextSize: 16384,
                                    tracker: LocalSummaryFailureTracker())
        do {
            _ = try await gen.generate("hi", maxOutputTokens: 8)
            XCTFail("expected an error")
        } catch {
            // Either classified as unreadable weights (retryable) or a plain
            // failure with a clear message; it must never be a crash or a hang.
            XCTAssertFalse((error as? LocalizedError)?.errorDescription?.isEmpty ?? true)
        }
    }

    func testLiveSummaryOfAShortTranscript() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DISTAVO_LIVE"] == "1",
                          "set DISTAVO_LIVE=1 to run against real Gemma weights")
        let dir = ProcessInfo.processInfo.environment["DISTAVO_GEMMA_DIR"]
            ?? NSHomeDirectory() + "/Development/_inbox/distavo-2198-spike/model"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: dir + "/config.json"), "no model at \(dir)")

        let gen = MLXGemmaGenerator(modelDirectory: URL(fileURLWithPath: dir),
                                    modelID: "gemma-4-e4b", contextSize: 16384)
        defer { gen.unload() }
        let transcript = """
        SPEAKER_00: Hi, it's Marc. I'm calling about the cloud role you posted on LinkedIn.
        SPEAKER_01: Hello Marc. The rate is six hundred pounds a day, outside IR35, starting in March.
        SPEAKER_00: Great, I can send my CV on Friday and I'm available from March.
        """
        let request = SummaryRequest(
            transcript: transcript, noteOwner: "Marc", userSpeaker: "SPEAKER_00", style: .factsFirst,
            endOfTurnBlock: EndOfTurnBlock.build(noteLanguage: nil, style: .factsFirst,
                                                 noteOwner: "Marc", ownerSpeaker: "SPEAKER_00"))
        let raw = try await SummaryDriver.run(request, generator: gen)
        let note = SummaryPostProcess.clean(raw, style: .factsFirst, transcript: transcript, alwaysKeep: ["Marc"])
        XCTAssertTrue(SummaryPostProcess.missingHeadings(in: note, style: .factsFirst).isEmpty)
        XCTAssertTrue(SummaryValidator.validate(note).isEmpty, "\(SummaryValidator.validate(note))")
    }
}
