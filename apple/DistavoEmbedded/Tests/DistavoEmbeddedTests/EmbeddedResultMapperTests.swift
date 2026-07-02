import XCTest
import WhisperKit
import SpeakerKit
import DistavoCore
@testable import DistavoEmbedded

final class EmbeddedResultMapperTests: XCTestCase {

    private func word(_ text: String, _ start: Float, _ end: Float) -> WordTiming {
        WordTiming(word: text, tokens: [], start: start, end: end, probability: 1)
    }

    // MARK: Non-diarized mapping

    func testPlainSegmentsMapToWhisperXShapeWithoutSpeaker() {
        let segments = [
            TranscriptionSegment(start: 0.0, end: 2.5, text: " Hello there. "),
            TranscriptionSegment(start: 2.5, end: 4.0, text: "General Kenobi."),
        ]
        let dict = EmbeddedResultMapper.whisperXDictionary(segments: segments)
        let out = dict["segments"] as? [[String: Any]]
        XCTAssertEqual(out?.count, 2)
        XCTAssertEqual(out?[0]["text"] as? String, "Hello there.")
        XCTAssertEqual(out?[0]["start"] as? Double, 0.0)
        XCTAssertEqual(out?[1]["end"] as? Double, 4.0)
        XCTAssertNil(out?[0]["speaker"], "non-diarized output must omit speaker")

        // And the pipeline's cleaner must accept it end-to-end.
        let cleaned = TranscriptCleaner.clean(TranscriptCleaner.segments(from: dict))
        XCTAssertTrue(cleaned.contains("Hello there."))
    }

    func testSpecialTokensAndEmptySegmentsAreDropped() {
        let segments = [
            TranscriptionSegment(start: 0, end: 1, text: "<|startoftranscript|><|en|> Hi<|endoftext|>"),
            TranscriptionSegment(start: 1, end: 2, text: "<|nospeech|>"),
            TranscriptionSegment(start: 2, end: 3, text: "   "),
        ]
        let out = EmbeddedResultMapper.whisperXDictionary(segments: segments)["segments"] as? [[String: Any]]
        XCTAssertEqual(out?.count, 1)
        XCTAssertEqual(out?[0]["text"] as? String, "Hi")
    }

    // MARK: Diarized mapping

    func testSpeakerGroupsMapToWhisperXSpeakerLabels() {
        let alice = SpeakerSegment(
            speaker: .speakerId(0), startTime: 0.0, endTime: 2.0, frameRate: 100,
            speakerWords: [
                SpeakerWordTiming(wordTiming: word(" Hello", 0.0, 0.8), speaker: .speakerId(0)),
                SpeakerWordTiming(wordTiming: word(" world.", 0.9, 2.0), speaker: .speakerId(0)),
            ])
        let bob = SpeakerSegment(
            speaker: .speakerId(1), startTime: 2.0, endTime: 3.5, frameRate: 100,
            speakerWords: [
                SpeakerWordTiming(wordTiming: word(" Hi.", 2.1, 3.5), speaker: .speakerId(1)),
            ])
        let dict = EmbeddedResultMapper.whisperXDictionary(speakerGroups: [[alice], [bob]])
        let out = dict["segments"] as? [[String: Any]]
        XCTAssertEqual(out?.count, 2)
        XCTAssertEqual(out?[0]["speaker"] as? String, "SPEAKER_00")
        XCTAssertEqual(out?[0]["text"] as? String, "Hello world.")
        XCTAssertEqual(out?[1]["speaker"] as? String, "SPEAKER_01")
        XCTAssertEqual(out?[1]["start"] as? Double, 2.0)

        // TranscriptCleaner groups them under speaker headers like WhisperX output.
        let cleaned = TranscriptCleaner.clean(TranscriptCleaner.segments(from: dict))
        XCTAssertTrue(cleaned.contains("SPEAKER_00"))
        XCTAssertTrue(cleaned.contains("SPEAKER_01"))
    }

    func testUnmatchedSpeakerOmitsLabelSoCleanerShowsUnknown() {
        let segment = SpeakerSegment(
            speaker: .noMatch, startTime: 0, endTime: 1, frameRate: 100,
            speakerWords: [SpeakerWordTiming(wordTiming: word("Mystery.", 0, 1), speaker: .noMatch)])
        let dict = EmbeddedResultMapper.whisperXDictionary(speakerGroups: [[segment]])
        let out = dict["segments"] as? [[String: Any]]
        XCTAssertEqual(out?.count, 1)
        XCTAssertNil(out?[0]["speaker"])
        let cleaned = TranscriptCleaner.clean(TranscriptCleaner.segments(from: dict))
        XCTAssertTrue(cleaned.contains("SPEAKER_UNKNOWN"))
    }
}

/// Full on-device engine test — downloads real models (hundreds of MB) and
/// needs Apple Silicon, so it only runs when explicitly requested:
///   DISTAVO_EMBEDDED_LIVE=1 DISTAVO_EMBEDDED_LIVE_AUDIO=/path/to/speech.wav \
///     swift test --filter EmbeddedLiveTests
final class EmbeddedLiveTests: XCTestCase {
    func testTranscribesRealAudioOnDevice() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["DISTAVO_EMBEDDED_LIVE"] == "1", "live embedded test not requested")
        guard let audioPath = env["DISTAVO_EMBEDDED_LIVE_AUDIO"] else {
            XCTFail("set DISTAVO_EMBEDDED_LIVE_AUDIO to a WAV file with speech"); return
        }
        var config = TranscribeConfig()
        config.backend = "embedded"
        config.embeddedModel = "small"
        config.diarize = env["DISTAVO_EMBEDDED_LIVE_DIARIZE"] == "1"
        let result = try await EmbeddedTranscriber.shared.transcribe(
            wavURL: URL(fileURLWithPath: audioPath), config: config)
        let cleaned = TranscriptCleaner.clean(TranscriptCleaner.segments(from: result))
        XCTAssertFalse(cleaned.isEmpty, "expected a non-empty transcript")
        print("=== embedded live transcript ===\n\(cleaned)")
    }
}
