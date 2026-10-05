import XCTest
import WhisperKit
import DistavoCore
@testable import DistavoEmbedded

/// Vikunja #2943: word timings survive the WhisperKit -> WhisperX mapping so the
/// segments sidecar can hold them.
final class EmbeddedResultMapperWordsTests: XCTestCase {
    func testWordsPassThroughTrimmedAndFeedTheSidecar() throws {
        var segment = TranscriptionSegment(start: 0, end: 2, text: " Hello there.")
        segment.words = [
            WordTiming(word: " Hello", tokens: [], start: 0, end: 0.5, probability: 1),
            WordTiming(word: " there.", tokens: [], start: 0.75, end: 2, probability: 1),
        ]
        let dict = EmbeddedResultMapper.whisperXDictionary(segments: [segment])
        let sidecar = try XCTUnwrap(TranscriptSegments(whisperXResult: dict))
        XCTAssertEqual(sidecar.segments[0].words?.map(\.word), ["Hello", "there."])
        XCTAssertEqual(sidecar.segments[0].words?[1].start, 0.75)
    }

    func testNoWordsMeansNoWordsKey() {
        let dict = EmbeddedResultMapper.whisperXDictionary(segments: [TranscriptionSegment(start: 0, end: 1, text: "Hi")])
        XCTAssertNil((dict["segments"] as? [[String: Any]])?[0]["words"])
    }
}
