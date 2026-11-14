import XCTest
import AVFoundation
@testable import DistavoCore

/// Vikunja #6668 (core only): find the silence between two meetings in one recording and cut there.
final class RecordingSplitTests: XCTestCase {

    private func loud(_ n: Int) -> [Float] { Array(repeating: 0.1, count: n) }
    private func quiet(_ n: Int) -> [Float] { Array(repeating: 0.0, count: n) }

    // MARK: silences

    func testFindsTheTwoMinuteGapOfTheRealRecording() {
        // 48 min of talk, 2 min of silence, 11 min of talk (seconds as windows)
        let w = loud(2884) + quiet(119) + loud(660)
        let s = RecordingSplit.silences(windowRMS: w)
        XCTAssertEqual(s, [.init(start: 2884, end: 3003)])
    }

    func testShortPausesLeadInAndTailAreNotSplitPoints() {
        XCTAssertTrue(RecordingSplit.silences(windowRMS: loud(100) + quiet(59) + loud(100)).isEmpty, "59 s < 60 s")
        XCTAssertTrue(RecordingSplit.silences(windowRMS: quiet(90) + loud(100)).isEmpty, "silent lead-in")
        XCTAssertTrue(RecordingSplit.silences(windowRMS: loud(100) + quiet(90)).isEmpty, "silent tail: TrailingSilence's job")
        XCTAssertEqual(RecordingSplit.silences(windowRMS: loud(5) + quiet(60) + loud(5)).count, 1, "exactly 60 s counts")
        XCTAssertEqual(RecordingSplit.silences(windowRMS: loud(5) + quiet(70) + loud(5) + quiet(80) + loud(5)).count, 2)
    }

    func testTheGateIsTheSilenceMonitorGate() {
        let near = [Float](repeating: StereoBalancer.noiseGate, count: 70)       // at the gate = silent
        XCTAssertEqual(RecordingSplit.silences(windowRMS: loud(5) + near + loud(5)).count, 1)
        let above = [Float](repeating: StereoBalancer.noiseGate * 1.5, count: 70)
        XCTAssertTrue(RecordingSplit.silences(windowRMS: loud(5) + above + loud(5)).isEmpty)
    }

    // MARK: candidates

    private func segs() -> TranscriptSegments {
        func seg(_ t: Double, _ sp: String) -> TranscriptSegments.Segment { .init(start: t, end: t + 5, text: "x", speaker: sp) }
        return TranscriptSegments(segments: [seg(10, "SPEAKER_00"), seg(300, "SPEAKER_01"), seg(2800, "SPEAKER_02"),
                                             seg(3010, "SPEAKER_00"), seg(3200, "SPEAKER_07")])
    }

    func testOnlySilencesWithDifferentSpeakerSetsAreCandidates() {
        let gap = RecordingSplit.Silence(start: 2884, end: 3003)
        let c = RecordingSplit.candidates(silences: [gap], segments: segs(), duration: 3700)
        XCTAssertEqual(c.count, 1)
        XCTAssertEqual(c[0].speakersBefore, ["SPEAKER_02"], "only the 5 minutes before the gap")
        XCTAssertEqual(c[0].speakersAfter, ["SPEAKER_00", "SPEAKER_07"])

        // same people on both sides: an ordinary break
        let same = TranscriptSegments(segments: [.init(start: 10, end: 15, text: "a", speaker: "SPEAKER_00"),
                                                 .init(start: 400, end: 405, text: "b", speaker: "SPEAKER_00")])
        XCTAssertTrue(RecordingSplit.candidates(silences: [.init(start: 100, end: 200)], segments: same, duration: 500).isEmpty)
    }

    func testNoDiarisationMeansNoSuggestion() {
        let gap = RecordingSplit.Silence(start: 2884, end: 3003)
        XCTAssertTrue(RecordingSplit.candidates(silences: [gap], segments: nil, duration: 3700).isEmpty)
        let unlabelled = TranscriptSegments(segments: [.init(start: 10, end: 15, text: "a"), .init(start: 3100, end: 3105, text: "b")])
        XCTAssertTrue(RecordingSplit.candidates(silences: [gap], segments: unlabelled, duration: 3700).isEmpty)
        // nothing said on one side
        let oneSided = TranscriptSegments(segments: [.init(start: 10, end: 15, text: "a", speaker: "SPEAKER_00")])
        XCTAssertTrue(RecordingSplit.candidates(silences: [gap], segments: oneSided, duration: 3700).isEmpty)
    }

    func testOnlyTheMinutesAroundTheGapAreCompared() {
        // A talks alone for 20 minutes; B joins 10 minutes after A started. A long pause later: not two meetings
        // unless the people next to the gap differ.
        func seg(_ t: Double, _ sp: String) -> TranscriptSegments.Segment { .init(start: t, end: t + 5, text: "x", speaker: sp) }
        let s = TranscriptSegments(segments: [seg(10, "A"), seg(1100, "A"), seg(1190, "A"), seg(1500, "A"), seg(1550, "B")])
        let gap = RecordingSplit.Silence(start: 1200, end: 1300)
        XCTAssertEqual(RecordingSplit.candidates(silences: [gap], segments: s, duration: 1800).count, 1,
                       "before = A, after = A and B inside the window")
        // someone who spoke early (outside the window) and again after: same set next to the gap
        let t = TranscriptSegments(segments: [seg(10, "B"), seg(1100, "A"), seg(1500, "A")])
        XCTAssertTrue(RecordingSplit.candidates(silences: [gap], segments: t, duration: 1800).isEmpty)
    }

    // MARK: ranges

    func testRangesKeepTwoSecondsEitherSideAndNeverOverlap() throws {
        let cut = try XCTUnwrap(RecordingSplit.ranges(for: .init(start: 2884, end: 3003), duration: 3663))
        XCTAssertEqual(cut.first, 0...2886)
        XCTAssertEqual(cut.second, 3001...3663)
        let tiny = try XCTUnwrap(RecordingSplit.ranges(for: .init(start: 100, end: 101), duration: 200))
        XCTAssertLessThanOrEqual(tiny.first.upperBound, tiny.second.lowerBound)
        XCTAssertNil(RecordingSplit.ranges(for: .init(start: 0, end: 90), duration: 200))
        XCTAssertNil(RecordingSplit.ranges(for: .init(start: 100, end: 200), duration: 200))
    }

    // MARK: names, sidecars, marks

    func testHalfNamesAndSidecars() {
        XCTAssertEqual(RecordingSplit.halfBases(of: "Meeting_2026-11-09_13.59.20").second, "Meeting_2026-11-09_13.59.20 part 2")
        let names = ["B.speakers.json", "B.language.json", "B.transcript.clean.txt", "B.segments.json",
                     "B.bookmarks.json", "Other.speakers.json", "B2.speakers.json"]
        XCTAssertEqual(RecordingSplit.sidecarsToCopy(names: names, base: "B"), ["B.language.json"],
                       "speakers.json describes the whole recording: each half asks its own")
    }

    func testMarksAreRetimedPerHalf() throws {
        let cut = try XCTUnwrap(RecordingSplit.ranges(for: .init(start: 2884, end: 3003), duration: 3663))
        let marks: [RecordingBookmarks.Mark] = [.init(offsetSeconds: 100, label: "a"), .init(offsetSeconds: 2890, label: "mid-early"),
                                                .init(offsetSeconds: 2999, label: "mid-late"), .init(offsetSeconds: 3101, label: "b")]
        let (a, b) = RecordingSplit.splitMarks(marks, cut: cut)
        XCTAssertEqual(a.map(\.label), ["a", "mid-early"])
        XCTAssertEqual(b.map(\.label), ["mid-late", "b"])
        XCTAssertEqual(b.last?.offsetSeconds, 3101 - 3001)
        XCTAssertEqual(b.first?.offsetSeconds, 0, "clamped at the start of the second half")
        XCTAssertEqual(a.count + b.count, marks.count)
    }

    // MARK: audio, end to end on a synthetic file

    /// 20 s at 8 kHz stereo: tone 0-6 s, silence 6-16 s, tone 16-20 s. Min silence 5 s to keep the file small.
    private func makeFile(_ url: URL) throws {
        let rate = 8000.0
        let file = try AVAudioFile(forWriting: url, settings: RecordingStorageFormat.int16.fileSettings(sampleRate: rate),
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let n = 20 * 8000
        let buf = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(n)))
        buf.frameLength = AVAudioFrameCount(n)
        for i in 0..<n {
            let t = Double(i) / rate
            let on = t < 6 || t >= 16
            let v: Float = on ? 0.3 * sinf(Float(i) * 0.2) : 0
            buf.floatChannelData![0][i] = v; buf.floatChannelData![1][i] = v / 2
        }
        try file.write(from: buf)
    }

    func testScanCutAndRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("rec.wav")
        try makeFile(src)

        let (rms, duration) = try RecordingSplit.windowRMS(of: src)
        XCTAssertEqual(duration, 20, accuracy: 0.01)
        let sil = RecordingSplit.silences(windowRMS: rms, minSeconds: 5)
        XCTAssertEqual(sil, [.init(start: 6, end: 16)])

        let cut = try XCTUnwrap(RecordingSplit.ranges(for: sil[0], duration: duration))
        let p1 = dir.appendingPathComponent("p1.wav"), p2 = dir.appendingPathComponent("p2.wav")
        let n1 = try RecordingSplit.cut(source: src, range: cut.first, destination: p1)
        let n2 = try RecordingSplit.cut(source: src, range: cut.second, destination: p2)
        XCTAssertEqual(n1, 8 * 8000)           // 0 ... 8 s
        XCTAssertEqual(n2, 6 * 8000)           // 14 ... 20 s
        let f1 = try AVAudioFile(forReading: p1), f2 = try AVAudioFile(forReading: p2)
        XCTAssertEqual(f1.length, n1); XCTAssertEqual(f2.length, n2)
        XCTAssertEqual(f1.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int, 16, "same file format as the source")
        XCTAssertEqual(f1.fileFormat.channelCount, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.path), "the original is kept")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix(".split-") }, [],
                       "no temp file left behind")

        // the second half starts with 2 s of silence and then the tone
        let (rms2, _) = try RecordingSplit.windowRMS(of: p2)
        XCTAssertLessThanOrEqual(rms2[0], StereoBalancer.noiseGate)
        XCTAssertGreaterThan(rms2[3], 0.05)
    }

    func testCutRejectsEmptyAndOutsideRanges() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("rec.wav"), out = dir.appendingPathComponent("o.wav")
        try makeFile(src)
        XCTAssertThrowsError(try RecordingSplit.cut(source: src, range: 30...40, destination: out)) {
            XCTAssertEqual($0 as? RecordingSplit.SplitError, .outsideFile)
        }
        XCTAssertThrowsError(try RecordingSplit.cut(source: src, range: 5...5, destination: out)) {
            XCTAssertEqual($0 as? RecordingSplit.SplitError, .emptyRange)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
    }
}
