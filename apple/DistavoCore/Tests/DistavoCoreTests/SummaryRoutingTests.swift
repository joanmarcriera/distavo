import XCTest
@testable import DistavoCore

/// The diagnostic activity-log line for the on-device summariser.
final class SummaryRoutingTraceTests: XCTestCase {

    private var apple: EmbeddedSummaryModel { EmbeddedSummaryModelCatalog.models.first { $0.id == EmbeddedSummaryModelCatalog.appleID }! }
    private var gemma: EmbeddedSummaryModel { EmbeddedSummaryModelCatalog.models.first { $0.engine == .mlx }! }

    private func line(_ model: EmbeddedSummaryModel, _ text: String, language: String? = nil,
                      template: SummaryTemplate? = nil) -> String {
        SummaryRouting.traceLine(model: model, transcript: text, noteOwner: "Marc", userSpeaker: "SPEAKER_00",
                                 style: .classic, noteLanguage: language, template: template)
    }

    func testShortTranscriptOnAppleModelIsSinglePassAtTheDefaultContext() {
        let l = line(apple, "SPEAKER_00: hello there")
        XCTAssertTrue(l.hasPrefix("Summariser \u{2014} model=apple engine=appleFoundationModels context=4096 "), l)
        XCTAssertTrue(l.contains("style=classic language=default"), l)
        XCTAssertTrue(l.hasSuffix("plan=single pass"), l)
        XCTAssertFalse(l.contains("template="), l)
    }

    func testCatalogueContextCapIsReported() {
        XCTAssertTrue(line(gemma, "SPEAKER_00: hi").contains("context=\(gemma.contextCap!) "))
        XCTAssertTrue(line(gemma, "SPEAKER_00: hi").contains("engine=mlx"))
    }

    func testLanguageIsShownWhenSet() {
        XCTAssertTrue(line(apple, "SPEAKER_00: hi", language: "ca").contains("language=ca"))
    }

    func testLongTranscriptOnSmallWindowPredictsMapReduce() {
        let long = (0..<1500).map { "SPEAKER_0\($0 % 2): Point \($0) about the migration timeline and budget." }
            .joined(separator: "\n")
        let l = line(apple, long)
        XCTAssertTrue(l.contains("plan=map-reduce ("), l)
        XCTAssertTrue(l.contains(" parts)"), l)
    }

    func testTokenEstimateMatchesTheHeuristic() {
        let text = "SPEAKER_00: " + String(repeating: "word ", count: 200)
        XCTAssertTrue(line(apple, text).contains("transcript\u{2248}\(EmbeddedSummaryTokens.estimate(text)) tokens"))
    }
}
