import XCTest
@testable import DistavoEmbedded
import DistavoCore

/// Voice profiles end to end on SYNTHETIC voices (macOS `say`): enrol two voices from one set of sentences,
/// then recognise them, and reject a third voice, on different sentences. No person's voice is involved.
/// SKIPPED unless `DISTAVO_VOICE_LIVE=1` (downloads FluidAudio's two diariser models on first run).
/// It proves the plumbing and prints the similarity scores; it does NOT calibrate the threshold for real
/// voices, rooms and microphones (docs/voice-profiles-plan.md, "Gates for Marc").
///
///   DISTAVO_VOICE_LIVE=1 swift test --filter VoiceEmbedderLiveTests
final class VoiceEmbedderLiveTests: XCTestCase {
    private let enrolText = "Good morning everyone. Thank you for joining the call today. I would like to start with the delivery schedule for next month, and then we can look at the open questions about the cooling units and the invoice from last week."
    private let laterText = "Before we finish, let me repeat what we agreed. The first shipment leaves on Tuesday, the second one a week later, and I will send the updated drawings to the whole team by Friday afternoon at the latest."

    private func speak(_ voice: String, _ text: String, into dir: URL, name: String) throws -> URL {
        let out = dir.appendingPathComponent("\(name).wav")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = ["-v", voice, "-o", out.path, "--data-format=LEI16@22050", text]
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0, FileManager.default.fileExists(atPath: out.path) else {
            throw XCTSkip("the system voice \(voice) is not installed")
        }
        return out
    }

    func testEnrolThenRecogniseSyntheticVoices() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DISTAVO_VOICE_LIVE"] == "1", "set DISTAVO_VOICE_LIVE=1")
        let dir = TestTemp.root.appendingPathComponent("voice-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let whole = ["voice": [0.2...12.0]]
        func sample(_ voice: String, _ text: String, _ name: String) async throws -> [Float] {
            let wav = try speak(voice, text, into: dir, name: name)
            let e = await VoiceEmbedder.embeddings(audio: wav, ranges: whole)
            return try XCTUnwrap(e["voice"], "no embedding for \(voice)")
        }
        let wasDownloaded = VoiceEmbedder.isDownloaded
        var store = VoiceProfileStore(model: VoiceProfileStore.builtInModel)
        let a1 = try await sample("Daniel", enrolText, "a1"), b1 = try await sample("Samantha", enrolText, "b1")
        XCTAssertTrue(store.enrol(name: "Voice A", sample: a1))
        XCTAssertTrue(store.enrol(name: "Voice B", sample: b1))
        let speakers = [
            "SPEAKER_00": try await sample("Daniel", laterText, "a2"),
            "SPEAKER_01": try await sample("Samantha", laterText, "b2"),
            "SPEAKER_02": try await sample("Fred", laterText, "c2"),
        ]
        print("LIVE voice model on disk before this run: \(wasDownloaded); dimension \(speakers["SPEAKER_00"]!.count)")
        for label in speakers.keys.sorted() {
            let scores = store.profiles.map { p in "\(p.name)=\(String(format: "%.3f", VoiceProfileStore.cosine(p.samples[0], speakers[label]!)))" }
            print("LIVE voice scores \(label): \(scores.joined(separator: " "))")
        }
        let m = store.match(speakers: speakers)
        XCTAssertEqual(m["SPEAKER_00"]?.name, "Voice A")
        XCTAssertEqual(m["SPEAKER_01"]?.name, "Voice B")
        XCTAssertNil(m["SPEAKER_02"], "a voice nobody enrolled must stay unnamed")
    }
}
