import XCTest
@testable import DistavoCore

/// #6353 pass 2: the channel labeller wired behind `transcribe.channel_speakers`.
/// Synthetic stereo fixtures only (L = mic, R = system audio); no real recordings.
final class ChannelSpeakersPipelineTests: XCTestCase {
    let sr = 16000.0

    /// 4 s: owner speaks 0-2 s (left), remote 2-4 s (right).
    func stereo() -> StereoChannels {
        let n = Int(4 * sr)
        var l = [Float](repeating: 0, count: n), r = l
        for i in 0..<n {
            let v = sinf(2 * .pi * 220 * Float(i) / Float(sr))
            if i < Int(2 * sr) { l[i] = v * 0.5; r[i] = v * 0.02 } else { l[i] = v * 0.02; r[i] = v * 0.5 }
        }
        return StereoChannels(left: l, right: r, sampleRate: sr)
    }

    /// An engine result with ONE speaker for everything (what a failed diariser gives).
    func engineResult() -> [String: Any] {
        let spans: [(Double, Double)] = [(0.1, 0.5), (0.6, 1.0), (1.1, 1.8), (2.1, 2.5), (2.6, 3.0), (3.1, 3.8)]
        let words = spans.enumerated().map { TimedWord(text: "w\($0.offset)", start: $0.element.0, end: $0.element.1) }
        return WordSpeakerAligner.whisperXDictionary(words: words, turns: [SpeakerTurn(speaker: 0, start: 0, end: 4)])
    }

    func speakers(_ r: [String: Any]) -> [String] {
        ((r["segments"] as? [[String: Any]]) ?? []).compactMap { $0["speaker"] as? String }
    }

    func testRelabelSplitsOwnerAndRemote() throws {
        let out = try XCTUnwrap(ChannelSpeakerLabeller.relabel(result: engineResult(), channels: stereo()))
        XCTAssertEqual(speakers(out), ["SPEAKER_00", "SPEAKER_01"])
    }

    func testRelabelNilWhenOneChannelSilent() {
        var s = stereo(); s.right = [Float](repeating: 0, count: s.right.count)
        XCTAssertNil(ChannelSpeakerLabeller.relabel(result: engineResult(), channels: s))
    }

    func testRelabelNilWithoutWordTimings() {
        let r: [String: Any] = ["segments": [["speaker": "SPEAKER_00", "text": "hi"]]]
        XCTAssertNil(ChannelSpeakerLabeller.relabel(result: r, channels: stereo()))
    }

    func testConfigFlagDefaultsOffAndRoundTrips() throws {
        XCTAssertFalse(TranscribeConfig().channelSpeakers)
        let old = try JSONDecoder().decode(TranscribeConfig.self, from: Data("{}".utf8))
        XCTAssertFalse(old.channelSpeakers)
        let on = try JSONDecoder().decode(TranscribeConfig.self, from: Data("{\"channel_speakers\":true}".utf8))
        XCTAssertTrue(on.channelSpeakers)
    }

    private func run(flag: Bool, channels: StereoChannels?) async throws -> [String] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("distavo-ch-\(UUID().uuidString)")
        let rec = root.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: rec, withIntermediateDirectories: true)
        let input = rec.appendingPathComponent("demo.opus")
        try Data([0, 1, 2, 3]).write(to: input)
        var cfg = Config()
        cfg.recordingsDir = rec.path
        cfg.notesDir = root.appendingPathComponent("notes").path
        cfg.workDir = root.appendingPathComponent("work").path
        cfg.transcribe.channelSpeakers = flag
        let result = engineResult()
        let deps = PipelineDeps(
            convertToWav: { _, dest in
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data([0]).write(to: dest)
            },
            transcribe: { _, _ in result },
            ollamaReachable: { _ in true },
            summarise: { _, _, _, _ in PipelineTests.validNote },
            audioDurationSeconds: { _ in nil },
            stereoChannels: { _ in channels })
        let r = await Pipeline.processOne(path: input, config: cfg, deps: deps, stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(r.status, .done)
        let side = try XCTUnwrap(TranscriptSegments.load(workDir: root.appendingPathComponent("work"), base: r.base))
        return side.segments.compactMap { $0.speaker }
    }

    func testPipelineRelabelsWhenFlagOnAndStereo() async throws {
        let s = try await run(flag: true, channels: stereo())
        XCTAssertEqual(Set(s), ["SPEAKER_00", "SPEAKER_01"])
    }

    func testPipelineUntouchedWhenFlagOff() async throws {
        let s = try await run(flag: false, channels: stereo())
        XCTAssertEqual(Set(s), ["SPEAKER_00"])
    }

    func testPipelineUntouchedWhenSourceIsNotStereo() async throws {
        let s = try await run(flag: true, channels: nil)
        XCTAssertEqual(Set(s), ["SPEAKER_00"])
    }
}
