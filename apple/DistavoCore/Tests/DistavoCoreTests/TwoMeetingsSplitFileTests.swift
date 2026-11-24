import AVFoundation
import XCTest
@testable import DistavoCore

/// The file side of "Was this two meetings?": cutting the held-back take in two and sending what was typed
/// and marked during the recording to the right half. Generated audio and invented text only.
final class TwoMeetingsSplitFileTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = TestTemp.root.appendingPathComponent("distavo-two-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private let rate = 8_000.0

    /// The value of frame `i` on channel `ch`: exact in 16-bit and in Float32, different on every frame nearby.
    private func value(_ i: Int, _ ch: Int) -> Float { Float((i + ch * 7) % 20_000 - 10_000) / 32_768 }

    /// A stereo take named like the recorder's held-back file (`….wav.part`), `seconds` long.
    private func take(_ name: String, seconds: Int, format: RecordingStorageFormat) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let pcm = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: format.fileSettings(sampleRate: rate),
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: AVAudioFrameCount(rate))!
        for s in 0..<seconds {
            buffer.frameLength = AVAudioFrameCount(rate)
            for ch in 0..<2 { for i in 0..<Int(rate) { buffer.floatChannelData![ch][i] = value(s * Int(rate) + i, ch) } }
            try file.write(from: buffer)
        }
        return url
    }

    private func frames(_ url: URL) throws -> [[Float]] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        return (0..<2).map { ch in Array(UnsafeBufferPointer(start: buffer.floatChannelData![ch], count: Int(buffer.frameLength))) }
    }

    private func bitDepth(_ url: URL) throws -> (bits: UInt32, float: Bool, rate: Double) {
        let format = try AVAudioFile(forReading: url).fileFormat   // kept alive: the description points into it
        let d = format.streamDescription.pointee
        return (d.mBitsPerChannel, d.mFormatFlags & kAudioFormatFlagIsFloat != 0, d.mSampleRate)
    }

    private func checkSplit(_ format: RecordingStorageFormat) throws {
        let part = try take("Meeting 2031-01-01 10.00.00.wav.part", seconds: 60, format: format)
        let second = dir.appendingPathComponent("Meeting 2031-01-01 10.00.35.5.wav.part")
        let cut = RecordingSplit.Cut(first: 0...20.25, second: 35.5...60)
        try TwoMeetingsSplit.splitPart(part: part, cut: cut, secondPart: second)

        let a = try frames(part), b = try frames(second)
        let secondStart = Int(35.5 * rate), total = Int(60 * rate)
        // The hole in the cut (20.25-35.5) is closed: the first half runs to where the second starts, so the
        // two halves are the whole take, sample-exact on both channels.
        XCTAssertEqual(a[0].count, secondStart)
        XCTAssertEqual(a[0].count + b[0].count, total)
        for ch in 0..<2 {
            XCTAssertEqual(a[ch] + b[ch], (0..<total).map { value($0, ch) }, "channel \(ch)")
        }
        // Same on-disk format as the recorder wrote: nothing was resampled or widened.
        for url in [part, second] {
            let f = try bitDepth(url)
            XCTAssertEqual(f.bits, UInt32(format.bitDepth))
            XCTAssertEqual(f.float, format == .full)
            XCTAssertEqual(f.rate, rate)
        }
        // No temporary file is left where the recovery of interrupted recordings or the scanner could find it.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(),
                       [part.lastPathComponent, second.lastPathComponent].sorted())
    }

    func testSplitsAFullQualityTakeSampleExact() throws { try checkSplit(.full) }
    func testSplitsACompactTakeSampleExact() throws { try checkSplit(.int16) }

    func testTheSecondHalfRunsToTheRealEndOfTheFile() throws {
        // The detector's clock said 57 s; the file holds 60.
        let part = try take("a.wav.part", seconds: 60, format: .int16)
        let second = dir.appendingPathComponent("b.wav.part")
        try TwoMeetingsSplit.splitPart(part: part, cut: .init(first: 0...20, second: 30...57), secondPart: second)
        XCTAssertEqual(try frames(second)[0].count, Int(30 * rate))
        XCTAssertEqual(try frames(part)[0].count, Int(30 * rate))
    }

    func testAClockThatDisagreesWithTheFileChangesNothing() throws {
        // A stalled audio device: the ticks counted 50 s (or 70), the file holds 60. The gap is not where the
        // ticks say, so nothing is cut.
        for said in [50.0, 70.0] {
            let part = try take("a.wav.part", seconds: 60, format: .int16)
            let second = dir.appendingPathComponent("b.wav.part")
            let before = try Data(contentsOf: part)
            XCTAssertThrowsError(try TwoMeetingsSplit.splitPart(part: part, cut: .init(first: 0...20, second: 30...said),
                                                                secondPart: second)) {
                XCTAssertEqual($0 as? TwoMeetingsSplit.SplitError, .clockMismatch)
            }
            XCTAssertEqual(try Data(contentsOf: part), before)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["a.wav.part"])
            try FileManager.default.removeItem(at: part)
        }
    }

    func testATakenNameChangesNothing() throws {
        let part = try take("a.wav.part", seconds: 10, format: .int16)
        let second = try take("b.wav.part", seconds: 1, format: .int16)
        let before = try Data(contentsOf: part), other = try Data(contentsOf: second)
        XCTAssertThrowsError(try TwoMeetingsSplit.splitPart(part: part, cut: .init(first: 0...4, second: 6...10), secondPart: second)) {
            XCTAssertEqual($0 as? TwoMeetingsSplit.SplitError, .nameTaken)
        }
        XCTAssertEqual(try Data(contentsOf: part), before)
        XCTAssertEqual(try Data(contentsOf: second), other)
    }

    func testACutOutsideTheFileChangesNothing() throws {
        let part = try take("a.wav.part", seconds: 10, format: .int16)
        let second = dir.appendingPathComponent("b.wav.part")
        let before = try Data(contentsOf: part)
        XCTAssertThrowsError(try TwoMeetingsSplit.splitPart(part: part, cut: .init(first: 0...11, second: 12...13), secondPart: second))
        XCTAssertEqual(try Data(contentsOf: part), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["a.wav.part"])
    }

    // MARK: What was typed and marked during the recording

    private let cut = RecordingSplit.Cut(first: 0...110, second: 190...600)

    func testTypedNotesAndKeyMomentsGoToTheHalfTheirTimeFallsIn() throws {
        var notes = ScratchpadNotes(lines: [
            .init(offsetSeconds: 0, text: "Objective: agree the plan", flagged: true),
            .init(offsetSeconds: 90, text: "budget question"),
            .init(offsetSeconds: 140, text: "typed in the first half of the gap"),
            .init(offsetSeconds: 170, text: "typed in the second half of the gap"),
            .init(offsetSeconds: 250, text: "second meeting, first point", flagged: true),
        ], people: "Ada, Grace")
        notes.version = 1
        try notes.save(workDir: dir, base: "one")
        try RecordingBookmarks(marks: [.init(offsetSeconds: 30, label: "a"), .init(offsetSeconds: 400.5, label: "b")],
                               source: "one.wav").save(workDir: dir, base: "one")

        let moved = try TwoMeetingsSplit.routeSidecars(workDir: dir, firstBase: "one", secondBase: "two",
                                                       cut: cut, secondSource: "two.wav")
        XCTAssertEqual(moved.lines, 2)
        XCTAssertEqual(moved.marks, 1)

        let first = try XCTUnwrap(ScratchpadNotes.load(workDir: dir, base: "one"))
        XCTAssertEqual(first.lines.map(\.text), ["Objective: agree the plan", "budget question", "typed in the first half of the gap"])
        XCTAssertEqual(first.lines.map(\.offsetSeconds), [0, 90, 140])
        XCTAssertEqual(first.people, "Ada, Grace")
        let second = try XCTUnwrap(ScratchpadNotes.load(workDir: dir, base: "two"))
        XCTAssertEqual(second.lines.map(\.text), ["typed in the second half of the gap", "second meeting, first point"])
        XCTAssertEqual(second.lines.map(\.offsetSeconds), [0, 60])
        XCTAssertEqual(second.lines.map(\.flagged), [false, true])
        XCTAssertNil(second.people, "the people typed are not timed: the second half is asked")

        XCTAssertEqual(RecordingBookmarks.load(workDir: dir, base: "one"),
                       RecordingBookmarks(marks: [.init(offsetSeconds: 30, label: "a")], source: "one.wav"))
        XCTAssertEqual(RecordingBookmarks.load(workDir: dir, base: "two"),
                       RecordingBookmarks(marks: [.init(offsetSeconds: 210.5, label: "b")], source: "two.wav"))
    }

    func testEverythingInTheFirstHalfLeavesTheFilesAlone() throws {
        try ScratchpadNotes(lines: [.init(offsetSeconds: 5, text: "early")]).save(workDir: dir, base: "one")
        try RecordingBookmarks(marks: [.init(offsetSeconds: 30)]).save(workDir: dir, base: "one")
        let before = try Data(contentsOf: ScratchpadNotes.url(workDir: dir, base: "one"))
        let moved = try TwoMeetingsSplit.routeSidecars(workDir: dir, firstBase: "one", secondBase: "two", cut: cut, secondSource: nil)
        XCTAssertEqual(moved.lines + moved.marks, 0)
        XCTAssertEqual(try Data(contentsOf: ScratchpadNotes.url(workDir: dir, base: "one")), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(),
                       ["one.bookmarks.json", "one.scratchpad.json"])
    }

    func testEverythingInTheSecondHalfLeavesNoEmptyFileBehind() throws {
        try ScratchpadNotes(lines: [.init(offsetSeconds: 300, text: "late")]).save(workDir: dir, base: "one")
        try RecordingBookmarks(marks: [.init(offsetSeconds: 300)]).save(workDir: dir, base: "one")
        try TwoMeetingsSplit.routeSidecars(workDir: dir, firstBase: "one", secondBase: "two", cut: cut, secondSource: nil)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(),
                       ["two.bookmarks.json", "two.scratchpad.json"])
    }

    func testMoreTypedLinesThanOneNoteTakesAreNotLostByTheSplit() throws {
        // 30 short lines: over the 20-line cap of one note, but 15 per half.
        let lines = (0..<30).map { ScratchpadNotes.Line(offsetSeconds: $0 < 15 ? $0 : 200 + $0, text: "line \($0)") }
        try ScratchpadNotes(lines: lines).save(workDir: dir, base: "one")
        try TwoMeetingsSplit.routeSidecars(workDir: dir, firstBase: "one", secondBase: "two", cut: cut, secondSource: nil)
        XCTAssertEqual(ScratchpadNotes.load(workDir: dir, base: "one")?.lines.count, 15)
        XCTAssertEqual(ScratchpadNotes.load(workDir: dir, base: "two")?.lines.count, 15)
    }

    func testNoSidecarsIsNotAnError() throws {
        let moved = try TwoMeetingsSplit.routeSidecars(workDir: dir, firstBase: "one", secondBase: "two", cut: cut, secondSource: nil)
        XCTAssertEqual(moved.lines + moved.marks, 0)
    }

    // MARK: The option

    func testTheQuestionIsOffForAConfigThatPredatesItAndForFreshInstalls() throws {
        let old = try JSONDecoder().decode(RecordingOptions.self, from: Data(#"{"mic_auto_switch": true}"#.utf8))
        XCTAssertFalse(old.askTwoMeetings)
        XCTAssertFalse(RecordingOptions().askTwoMeetings)
        XCTAssertFalse(Config.recommendedForThisMac().recording.askTwoMeetings)
    }

    func testTheOptionRoundTripsAndAWrongTypeIsOff() throws {
        var on = RecordingOptions()
        on.askTwoMeetings = true
        let data = try JSONEncoder().encode(on)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(#""ask_two_meetings":true"#))
        XCTAssertTrue(try JSONDecoder().decode(RecordingOptions.self, from: data).askTwoMeetings)
        let wrong = try JSONDecoder().decode(RecordingOptions.self, from: Data(#"{"ask_two_meetings": "yes"}"#.utf8))
        XCTAssertFalse(wrong.askTwoMeetings)
    }
}
