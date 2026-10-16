import XCTest
@testable import DistavoCore

/// Vikunja #3580: the speaker count follows the participants text, warns on mismatch and defaults to auto.
final class SpeakerCountTests: XCTestCase {

    func testSuggestedCountIsOthersPlusOwner() {
        XCTAssertEqual(SpeakerHints.suggestedCount("Me: x. Other participants: A (CEO), B (IT), C"), 4)
        XCTAssertEqual(SpeakerHints.suggestedCount("Other participants: Edward, Cambridge University — interviewer"), 3)
        XCTAssertEqual(SpeakerHints.suggestedCount("Other participants: Anna (CEO, Acme); Bernat\nCarla"), 4)
    }

    func testDescriptionsAndRolesAreNotCountedAsPeople() {
        // The 2026-09-29 meeting: one named person, then a description of his company.
        let text = "Me (me): Meeting en català. Other participants: Francesc Queralt, CEO de btmdata.com , una empresa que es dedica a fer projectes"
        XCTAssertEqual(SpeakerHints.suggestedCount(text), 2)
    }

    func testNoListMeansNoSuggestion() {
        XCTAssertNil(SpeakerHints.suggestedCount(nil))
        XCTAssertNil(SpeakerHints.suggestedCount("Me (me): note taker"))
        XCTAssertNil(SpeakerHints.suggestedCount("Other participants: "))
    }

    func testMismatchWarning() {
        let t = "Me: x. Other participants: A (CEO), B (IT), C"
        XCTAssertEqual(SpeakerHints.mismatchWarning(count: 2, participants: t), "4 people listed but 2 speakers set")
        XCTAssertNil(SpeakerHints.mismatchWarning(count: 4, participants: t))
        XCTAssertNil(SpeakerHints.mismatchWarning(count: nil, participants: t), "auto never mismatches")
        XCTAssertNil(SpeakerHints.mismatchWarning(count: 0, participants: t))
        XCTAssertNil(SpeakerHints.mismatchWarning(count: 2, participants: "Me: x"))
    }

    func testDefaultIsAutomaticAndWhisperXOmitsTheCount() async throws {
        XCTAssertEqual(TranscribeConfig().numSpeakers, 0)
        let cfg = try JSONDecoder().decode(TranscribeConfig.self, from: Data("{}".utf8))
        XCTAssertEqual(cfg.numSpeakers, 0)
        let kept = try JSONDecoder().decode(TranscribeConfig.self, from: Data(#"{"num_speakers": 3}"#.utf8))
        XCTAssertEqual(kept.numSpeakers, 3, "a saved value is kept")

        let wav = FileManager.default.temporaryDirectory.appendingPathComponent("distavo-\(UUID().uuidString).wav")
        try Data([0, 1, 2, 3]).write(to: wav)
        defer { try? FileManager.default.removeItem(at: wav) }
        let session = MockURLProtocol.session { req in
            XCTAssertFalse((req.url?.query ?? "").contains("num_speakers"), "auto sends no count")
            return try MockURLProtocol.ok(req.url!, json: ["segments": [["start": 0.0, "end": 1.0, "text": "hi"]]])
        }
        _ = try await WhisperXClient(session: session).transcribe(wavURL: wav, config: TranscribeConfig())
    }
}

/// Vikunja #3586: in-person (microphone only) capture is remembered in the speakers sidecar.
final class InPersonCaptureTests: XCTestCase {
    func testCaptureKeepsTheHintAliveAndRoundTrips() throws {
        let hints = SpeakerHints(capture: SpeakerHints.inPersonCapture)
        XCTAssertFalse(hints.isEmpty, "the capture mode alone is worth saving")
        let back = try JSONDecoder().decode(SpeakerHints.self, from: JSONEncoder().encode(hints))
        XCTAssertEqual(back.capture, "in_person")
        XCTAssertNil(try JSONDecoder().decode(SpeakerHints.self, from: Data(#"{"count": 3}"#.utf8)).capture)
        XCTAssertTrue(SpeakerHints().isEmpty)
    }
}
