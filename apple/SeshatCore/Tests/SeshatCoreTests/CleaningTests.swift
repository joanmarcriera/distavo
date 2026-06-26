import XCTest
@testable import SeshatCore

final class CleaningTests: XCTestCase {

    private func loadFixture() throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "whisperx-sample", withExtension: "json"))
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testNormaliseSpaceCollapsesWhitespace() {
        XCTAssertEqual(TranscriptCleaner.normaliseSpace("  a\n\t b  "), "a b")
    }

    func testSegmentsFromResultExtractsSpeakerAndText() throws {
        let segments = TranscriptCleaner.segments(from: try loadFixture())
        XCTAssertEqual(segments.count, 4)
        XCTAssertEqual(segments[0].speaker, "SPEAKER_00")
        XCTAssertEqual(segments[0].text, "Hello, thanks for joining.")
    }

    func testCleanTranscriptGroupsTurnsAndDropsTimestamps() throws {
        let out = TranscriptCleaner.clean(TranscriptCleaner.segments(from: try loadFixture()))
        XCTAssertNil(out.range(of: "\\[\\d+:\\d{2}", options: .regularExpression))
        XCTAssertEqual(out.components(separatedBy: "[SPEAKER_00]").count - 1, 2)
        XCTAssertEqual(out.components(separatedBy: "[SPEAKER_01]").count - 1, 1)
        XCTAssertTrue(out.contains("Hello, thanks for joining. Let's talk about the GPU cluster."))
    }

    func testCleanTranscriptEmptyWhenNoSegments() {
        XCTAssertEqual(TranscriptCleaner.clean([]), "")
    }

    func testTextListVariant() {
        let result: [String: Any] = ["text": [["speaker": "SPEAKER_00", "text": "hi"], "plain line"]]
        let segments = TranscriptCleaner.segments(from: result)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].speaker, "SPEAKER_00")
        XCTAssertEqual(segments[1].speaker, "SPEAKER_UNKNOWN")
        XCTAssertEqual(segments[1].text, "plain line")
    }

    func testPlainTextVariant() {
        let segments = TranscriptCleaner.segments(from: ["text": "just a string"])
        XCTAssertEqual(segments, [Segment(speaker: "SPEAKER_UNKNOWN", text: "just a string")])
    }
}
