import XCTest
import AVFoundation
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

    /// Review 2026-11-07: the relabel must not drop `detections` / `engine` (language + provenance footer read them).
    func testRelabelKeepsNonSegmentKeys() throws {
        var r = engineResult()
        r["engine"] = "whisperkit"
        r["detections"] = [["language": "ca", "confidence": 0.9]]
        let out = try XCTUnwrap(ChannelSpeakerLabeller.relabel(result: r, channels: stereo()))
        XCTAssertEqual(out["engine"] as? String, "whisperkit")
        XCTAssertNotNil(out["detections"])
    }

    /// Review 2026-11-07 (HIGH): a numeral comes back from the engine without start/end. It must survive the relabel.
    func testRelabelKeepsUntimedWords() throws {
        let timed: [[String: Any]] = [
            ["word": "call", "start": 0.1, "end": 0.5], ["word": "42", "speaker": "SPEAKER_00"],
            ["word": "me", "start": 1.1, "end": 1.8], ["word": "then", "start": 2.1, "end": 2.5],
            ["word": "7", "speaker": "SPEAKER_00"], ["word": "ok", "start": 2.6, "end": 3.0],
            ["word": "fine", "start": 3.1, "end": 3.4], ["word": "good", "start": 3.5, "end": 3.9]]
        let r: [String: Any] = ["segments": [["speaker": "SPEAKER_00", "text": "x", "words": timed]]]
        let out = try XCTUnwrap(ChannelSpeakerLabeller.relabel(result: r, channels: stereo()))
        let text = ((out["segments"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined(separator: " ")
        XCTAssertTrue(text.contains("42"), text)
        XCTAssertTrue(text.contains("7"), text)
        XCTAssertEqual(speakers(out), ["SPEAKER_00", "SPEAKER_01"])
    }

    /// Review 2026-11-07: reading a file must not hold every sample; the stereo file reads as a compact envelope that
    /// still labels correctly.
    func testReadStreamsAnEnvelopeNotEverySample() throws {
        let s = stereo()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ch-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let fmt = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr, channels: 2, interleaved: false))
        let buf = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(s.left.count)))
        buf.frameLength = AVAudioFrameCount(s.left.count)
        for i in 0..<s.left.count { buf.floatChannelData![0][i] = s.left[i]; buf.floatChannelData![1][i] = s.right[i] }
        do { let f = try AVAudioFile(forWriting: url, settings: fmt.settings); try f.write(from: buf) }
        let got = try XCTUnwrap(StereoChannels.read(from: url))
        XCTAssertLessThan(got.left.count, s.left.count / 50, "an envelope, not the samples")
        let out = try XCTUnwrap(ChannelSpeakerLabeller.relabel(result: engineResult(), channels: got))
        XCTAssertEqual(speakers(out), ["SPEAKER_00", "SPEAKER_01"])
    }

    /// A run of numerals must not outvote the words around it (review): they inherit the previous word's side.
    func testRunOfUntimedWordsInheritsPreviousSide() throws {
        var words: [[String: Any]] = [["word": "hello", "start": 0.1, "end": 0.5], ["word": "there", "start": 0.6, "end": 1.0]]
        for d in ["2", "0", "2", "6"] { words.append(["word": d]) }
        words.append(["word": "yes", "start": 2.1, "end": 2.5]); words.append(["word": "ok", "start": 2.6, "end": 3.0])
        words.append(["word": "fine", "start": 3.1, "end": 3.4]); words.append(["word": "good", "start": 3.5, "end": 3.9])
        let r: [String: Any] = ["segments": [["speaker": "SPEAKER_00", "text": "x", "words": words]]]
        let out = try XCTUnwrap(ChannelSpeakerLabeller.relabel(result: r, channels: stereo()))
        let segs = (out["segments"] as? [[String: Any]]) ?? []
        XCTAssertTrue((segs.first?["text"] as? String ?? "").contains("2 0 2 6"), "digits stay with the owner turn")
        XCTAssertEqual(speakers(out), ["SPEAKER_00", "SPEAKER_01"])
    }

    /// Review 2026-11-08 (MEDIUM-HIGH): a segment with text but no words must not vanish; keep the engine labels.
    func testRelabelNilWhenASegmentHasTextButNoWords() {
        var r = engineResult()
        var segs = (r["segments"] as? [[String: Any]]) ?? []
        segs.append(["speaker": "SPEAKER_00", "text": "2025."])
        r["segments"] = segs
        XCTAssertNil(ChannelSpeakerLabeller.relabel(result: r, channels: stereo()))
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

    private func run(flag: Bool, channels: StereoChannels?, numSpeakers: Int = 0, participants: String? = nil) async throws -> [String] {
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
        cfg.transcribe.numSpeakers = numSpeakers
        if let participants {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("work"), withIntermediateDirectories: true)
            try SpeakerHints(participants: participants).save(workDir: root.appendingPathComponent("work"),
                                                              base: DistavoState.baseFor(recordingsDir: rec, path: input))
        }
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

    /// Review 2026-11-08: auto speaker count + a participants sheet naming three remote people must not use the channels.
    func testPipelineKeepsEngineLabelsWhenParticipantsNameManyPeopleOnAuto() async throws {
        let s = try await run(flag: true, channels: stereo(), participants: "Other participants: Anna, Ben, Carla")
        XCTAssertEqual(Set(s), ["SPEAKER_00"])
    }

    /// Review 2026-11-07: the flag forced two speakers on a call known to have three or more people.
    func testPipelineKeepsEngineLabelsWhenThreeOrMorePeopleAreExpected() async throws {
        let s = try await run(flag: true, channels: stereo(), numSpeakers: 3)
        XCTAssertEqual(Set(s), ["SPEAKER_00"])
    }
}
