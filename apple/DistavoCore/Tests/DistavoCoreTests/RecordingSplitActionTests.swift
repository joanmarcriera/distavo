import AVFoundation
import XCTest
@testable import DistavoCore

/// "Split recording…" from the Notes window (D077, D078, task 6668): the file side of the split. An extension of
/// `RecordingSplitTests` so `swift test --filter RecordingSplitTests` runs these. Synthetic audio only.
extension RecordingSplitTests {
    /// 20 s at 8 kHz stereo: tone 0-6 s, silence 6-16 s, tone 16-20 s.
    private func synthetic(_ url: URL) throws {
        let rate = 8000.0
        let file = try AVAudioFile(forWriting: url, settings: RecordingStorageFormat.int16.fileSettings(sampleRate: rate),
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let n = 20 * 8000
        let buf = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(n)))
        buf.frameLength = AVAudioFrameCount(n)
        for i in 0..<n {
            let on = Double(i) / rate < 6 || Double(i) / rate >= 16
            let v: Float = on ? 0.3 * sinf(Float(i) * 0.2) : 0
            buf.floatChannelData![0][i] = v; buf.floatChannelData![1][i] = v / 2
        }
        try file.write(from: buf)
    }

    private struct Folders { let root, rec, notes, work: URL; let source: URL }

    private func folders(withNote: Bool = true) throws -> Folders {
        let root = TestTemp.root.appendingPathComponent("distavo-split-\(UUID().uuidString)")
        let rec = root.appendingPathComponent("recordings"), notes = root.appendingPathComponent("notes")
        let work = root.appendingPathComponent("work")
        for d in [rec, notes, work] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        let source = rec.appendingPathComponent("Meeting_2026-11-18_09.00.00.wav")
        try synthetic(source)
        if withNote {
            try "# Two calls in one\n\nEdited by hand.\n".write(to: notes.appendingPathComponent("Meeting_2026-11-18_09.00.00.md"),
                                                             atomically: true, encoding: .utf8)
        }
        try #"{"code":"en"}"#.write(to: work.appendingPathComponent("Meeting_2026-11-18_09.00.00.language.json"),
                                    atomically: true, encoding: .utf8)
        try #"{"participants":"everyone"}"#.write(to: work.appendingPathComponent("Meeting_2026-11-18_09.00.00.speakers.json"),
                                                  atomically: true, encoding: .utf8)
        return Folders(root: root, rec: rec, notes: notes, work: work, source: source)
    }

    private func split(_ f: Folders, silence: RecordingSplit.Silence = .init(start: 6, end: 16)) throws -> RecordingSplitAction.Outcome {
        try RecordingSplitAction.perform(source: f.source, silence: silence, duration: 20,
                                         recordingsDir: f.rec, notesDir: f.notes, workDir: f.work,
                                         now: Date(timeIntervalSince1970: 1_795_400_000))
    }

    func testHalfBasesDoNotCollideWithExistingBases() {
        XCTAssertEqual(RecordingSplit.halfBases(of: "call", existing: []).first, "call part 1")
        let taken: Set<String> = ["call part 1", "call part 2 (2)"]
        let next = RecordingSplit.halfBases(of: "call", existing: taken)
        XCTAssertFalse(taken.contains(next.first)); XCTAssertFalse(taken.contains(next.second))
        XCTAssertEqual(next.first, "call part 1 (3)")
        XCTAssertEqual(next.second, "call part 2 (3)")
    }

    func testSplitKeepsTheOriginalAudioAndTheOldNoteAsABackup() throws {
        let f = try folders()
        let audioBefore = try Data(contentsOf: f.source)
        let noteURL = f.notes.appendingPathComponent("Meeting_2026-11-18_09.00.00.md")
        let noteBefore = try Data(contentsOf: noteURL)
        let out = try split(f)
        XCTAssertEqual(try Data(contentsOf: f.source), audioBefore, "the original audio is unchanged in place")
        let backup = try XCTUnwrap(out.noteBackup)
        XCTAssertTrue(NoteVersions.isBackupName(backup.lastPathComponent))
        XCTAssertEqual(try Data(contentsOf: backup), noteBefore, "the old note is kept byte for byte")
        XCTAssertFalse(FileManager.default.fileExists(atPath: noteURL.path))
        // The original is not reprocessed: it is done.
        let state = try DistavoState.Store(stateDir: f.work.appendingPathComponent(".state"), notesDir: f.notes)
        XCTAssertTrue(state.isDone("Meeting_2026-11-18_09.00.00"))
        // Two halves beside it, pending (no marker yet).
        XCTAssertEqual(out.first.lastPathComponent, "Meeting_2026-11-18_09.00.00 part 1.wav")
        XCTAssertEqual(out.second.lastPathComponent, "Meeting_2026-11-18_09.00.00 part 2.wav")
        XCTAssertEqual(try AVAudioFile(forReading: out.first).length, 8 * 8000)
        XCTAssertEqual(try AVAudioFile(forReading: out.second).length, 6 * 8000)
        XCTAssertFalse(state.isDone(out.firstBase)); XCTAssertFalse(state.isDone(out.secondBase))
    }

    func testSidecarsAreCopiedNotMoved() throws {
        let f = try folders()
        let out = try split(f)
        let original = f.work.appendingPathComponent("Meeting_2026-11-18_09.00.00.language.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path), "still there")
        for base in [out.firstBase, out.secondBase] {
            XCTAssertEqual(try String(contentsOf: f.work.appendingPathComponent("\(base).language.json"), encoding: .utf8),
                           #"{"code":"en"}"#)
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.work.appendingPathComponent("\(base).speakers.json").path),
                           "the participants describe the whole recording: not copied")
        }
    }

    func testMarksLandInTheRightHalf() throws {
        let f = try folders()
        try RecordingBookmarks(marks: [.init(offsetSeconds: 3, label: "a"), .init(offsetSeconds: 18, label: "b")])
            .save(workDir: f.work, base: "Meeting_2026-11-18_09.00.00")
        let out = try split(f)
        XCTAssertEqual(RecordingBookmarks.load(workDir: f.work, base: out.firstBase)?.marks.map(\.label), ["a"])
        let second = try XCTUnwrap(RecordingBookmarks.load(workDir: f.work, base: out.secondBase))
        XCTAssertEqual(second.marks.map(\.label), ["b"])
        XCTAssertEqual(second.marks.first?.offsetSeconds ?? -1, 18 - 14, accuracy: 0.01)
    }

    func testSplitOutsideTheFileTouchesNothing() throws {
        let f = try folders()
        func listing() throws -> [String] {
            try [f.rec, f.notes, f.work].flatMap { try FileManager.default.contentsOfDirectory(atPath: $0.path) }.sorted()
        }
        let before = try listing()
        XCTAssertThrowsError(try split(f, silence: .init(start: 25, end: 30)))
        XCTAssertThrowsError(try split(f, silence: .init(start: 0, end: 5)))
        XCTAssertEqual(try listing(), before)
    }

    func testSecondSplitPicksNewNames() throws {
        let f = try folders(withNote: false)
        let a = try split(f)
        let b = try split(f)
        XCTAssertNotEqual(a.firstBase, b.firstBase)
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.first.path), "the first split's halves are kept")
    }
    // Review round 2 (drive 2026-11-23).
    func testAFailureAfterTheCutTakesEverythingBack() throws {
        let f = try folders()
        // The notes folder refuses the backup move: the last step fails.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: f.notes.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.notes.path) }
        let recBefore = try FileManager.default.contentsOfDirectory(atPath: f.rec.path).sorted()
        let workBefore = try FileManager.default.contentsOfDirectory(atPath: f.work.path).filter { $0 != ".state" }.sorted()
        XCTAssertThrowsError(try split(f))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.rec.path).sorted(), recBefore)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.work.path).filter { $0 != ".state" }.sorted(), workBefore)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.notes.appendingPathComponent("Meeting_2026-11-18_09.00.00.md").path))
        let state = try DistavoState.Store(stateDir: f.work.appendingPathComponent(".state"), notesDir: f.notes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.work.appendingPathComponent(".state/Meeting_2026-11-18_09.00.00.done").path),
                       "not marked done when the split did not happen")
        _ = state
    }

    func testPartTwoOfARecorderNameIsDatedAtItsOwnStart() throws {
        XCTAssertEqual(RecordingSplitAction.restamped("Meeting 2026-11-18 09.00.00 part 2", by: 3000,
                                                      timeZone: TimeZone(identifier: "UTC")!),
                       "Meeting 2026-11-18 09.50.00 part 2")
        XCTAssertEqual(RecordingSplitAction.restamped("call part 2", by: 3000), "call part 2")
        let f = try folders(withNote: false)
        let out = try split(f)
        let created1 = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: out.first.path)[.creationDate] as? Date)
        let created2 = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: out.second.path)[.creationDate] as? Date)
        XCTAssertEqual(created2.timeIntervalSince(created1), 14, accuracy: 1, "part 2 starts 14 s into the original")
    }
}
