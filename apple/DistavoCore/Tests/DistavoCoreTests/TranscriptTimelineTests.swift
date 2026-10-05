import XCTest
@testable import DistavoCore

/// Vikunja #2951: timeline lookup, edit application, byte-identical render,
/// save/revert with originals preserved, and regenerate-after-edit.
final class TranscriptTimelineTests: XCTestCase {

    typealias W = TranscriptSegments.Word
    typealias S = TranscriptSegments.Segment

    private func sample() -> TranscriptSegments {
        TranscriptSegments(segments: [
            S(start: 0, end: 2, text: "hello brave world", speaker: "SPEAKER_00",
              words: [W(word: "hello", start: 0, end: 0.5), W(word: "brave", start: 0.6, end: 1.0),
                      W(word: "world", start: 1.2, end: 2)]),
            S(start: 2, end: 4, text: "second line", speaker: "SPEAKER_00"),   // no words
            S(start: 10, end: 12, text: "other speaker", speaker: "SPEAKER_01",
              words: [W(word: "other", start: 10, end: 11), W(word: "speaker", start: 11, end: 12)]),
        ])
    }

    private func tmp() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("distavo-tl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    // MARK: layout and lookup

    func testLayoutHeadersParagraphsAndWordRanges() {
        let l = TranscriptLayout(sample())
        XCTAssertEqual(l.text, "SPEAKER_00  ·  0:00\nhello brave world\nsecond line\nSPEAKER_01  ·  0:10\nother speaker")
        let ns = l.text as NSString
        XCTAssertEqual(l.tokens.count, 3 + 1 + 2)
        XCTAssertEqual(ns.substring(with: l.tokens[1].range), "brave")
        XCTAssertTrue(l.tokens[1].isWord)
        XCTAssertEqual(ns.substring(with: l.tokens[3].range), "second line")   // segment-level
        XCTAssertFalse(l.tokens[3].isWord)
        XCTAssertEqual(ns.substring(with: l.tokens[5].range), "speaker")
    }

    func testTokenAtTimeGapsOverlapsAndBounds() {
        let l = TranscriptLayout(sample())
        XCTAssertNil(l.tokenIndex(at: -1))
        XCTAssertEqual(l.tokenIndex(at: 0), 0)
        XCTAssertEqual(l.tokenIndex(at: 0.55), 0)          // short gap: previous word held
        XCTAssertEqual(l.tokenIndex(at: 0.6), 1)
        XCTAssertEqual(l.tokenIndex(at: 3), 3)             // segment-level token
        XCTAssertEqual(l.tokenIndex(at: 4.5), 3)           // within holdGap after end
        XCTAssertNil(l.tokenIndex(at: 7))                  // long silence
        XCTAssertEqual(l.tokenIndex(at: 11.5), 5)
        XCTAssertNil(l.tokenIndex(at: 500))                // past the end
        XCTAssertNil(l.tokenIndex(at: .nan))
    }

    func testOverlapLatestStartedWinsAndZeroLengthWords() {
        let t = TranscriptSegments(segments: [
            S(start: 0, end: 5, text: "a b", speaker: "X", words: [W(word: "a", start: 0, end: 5), W(word: "b", start: 1, end: 1)]),
        ])
        let l = TranscriptLayout(t)
        XCTAssertEqual(l.tokenIndex(at: 0.5), 0)
        XCTAssertEqual(l.tokenIndex(at: 1), 1)             // zero-length token is hit at its start
        XCTAssertEqual(l.tokenIndex(at: 2), 1)             // latest-started wins
    }

    func testUnsortedSegmentsStillLookUpByTime() {
        let t = TranscriptSegments(segments: [
            S(start: 10, end: 12, text: "late", speaker: "X"),
            S(start: 0, end: 2, text: "early", speaker: "X"),
        ])
        let l = TranscriptLayout(t)
        let i = l.tokenIndex(at: 1)!
        XCTAssertEqual((l.text as NSString).substring(with: l.tokens[i].range), "early")
    }

    func testTimeForCharacterIndex() {
        let l = TranscriptLayout(sample())
        let ns = l.text as NSString
        let brave = ns.range(of: "brave")
        XCTAssertEqual(l.time(forCharacterIndex: brave.location + 2), 0.6)
        // Between words (the space after "hello") -> the word before.
        let hello = ns.range(of: "hello")
        XCTAssertEqual(l.time(forCharacterIndex: hello.location + hello.length), 0)
        XCTAssertEqual(l.time(forCharacterIndex: ns.range(of: "second").location + 3), 2)
        XCTAssertEqual(l.time(forCharacterIndex: 0), 0)                                    // header
        XCTAssertEqual(l.time(forCharacterIndex: ns.range(of: "SPEAKER_01").location), 10) // header
        XCTAssertNil(l.time(forCharacterIndex: -1))
        XCTAssertNil(l.time(forCharacterIndex: ns.length + 5))
        XCTAssertEqual(l.time(forCharacterIndex: ns.length), 11)                            // end of last word
    }

    func testLookupIsFastOnATwoHourTranscript() {
        var segs: [S] = []
        for i in 0..<2000 {
            let t = Double(i) * 3.6
            segs.append(S(start: t, end: t + 3.5, text: (0..<10).map { "w\($0)" }.joined(separator: " "),
                          speaker: "SPEAKER_0\(i % 2)",
                          words: (0..<10).map { W(word: "w\($0)", start: t + Double($0) * 0.35, end: t + Double($0) * 0.35 + 0.3) }))
        }
        let l = TranscriptLayout(TranscriptSegments(segments: segs))
        XCTAssertEqual(l.tokens.count, 20000)
        measure { for k in 0..<20000 { _ = l.tokenIndex(at: Double(k) * 0.36); _ = l.time(forCharacterIndex: k * 3) } }
    }

    // MARK: edits

    func testApplyEditsDropsWordsOnlyForTextChange() {
        let edited = TranscriptEditing.applyEdits([
            0: SegmentEdit(text: "hello  bold world"),
            2: SegmentEdit(text: "other speaker", speaker: "SPEAKER_02"),
        ], to: sample())
        XCTAssertEqual(edited.segments[0].text, "hello bold world")
        XCTAssertNil(edited.segments[0].words)
        XCTAssertEqual(edited.segments[0].start, 0); XCTAssertEqual(edited.segments[0].end, 2)
        XCTAssertEqual(edited.segments[1], sample().segments[1])
        XCTAssertEqual(edited.segments[2].speaker, "SPEAKER_02")
        XCTAssertEqual(edited.segments[2].words?.count, 2)   // speaker-only change keeps words
    }

    func testBlankTextRemovesSegment() {
        let edited = TranscriptEditing.applyEdits([1: SegmentEdit(text: "   ")], to: sample())
        XCTAssertEqual(edited.segments.map(\.text), ["hello brave world", "other speaker"])
    }

    func testEditsFromDisplayedText() throws {
        let t = sample()
        let l = TranscriptLayout(t)
        XCTAssertEqual(l.edits(from: l.text, original: t), [:])
        let changed = l.text.replacingOccurrences(of: "brave", with: "bold")
        XCTAssertEqual(l.edits(from: changed, original: t), [0: SegmentEdit(text: "hello bold world")])
        XCTAssertNil(l.edits(from: l.text + "\nextra", original: t))   // structure changed
    }

    func testChangeGuard() {
        let l = TranscriptLayout(sample())
        let hdr = l.headerLineIndices
        let ns = l.text as NSString
        let brave = ns.range(of: "brave")
        XCTAssertTrue(TranscriptLayout.isAllowedChange(in: l.text, range: brave, replacement: "bold", headerLines: hdr))
        XCTAssertFalse(TranscriptLayout.isAllowedChange(in: l.text, range: brave, replacement: "a\nb", headerLines: hdr))
        XCTAssertFalse(TranscriptLayout.isAllowedChange(in: l.text, range: NSRange(location: 2, length: 1), replacement: "x", headerLines: hdr))
        let crossing = NSRange(location: brave.location, length: 40)
        XCTAssertFalse(TranscriptLayout.isAllowedChange(in: l.text, range: crossing, replacement: "", headerLines: hdr))
    }

    // MARK: render parity

    func testUneditedSidecarRendersByteIdenticalToPipelineCache() async throws {
        let root = try tmp()
        let rec = root.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: rec, withIntermediateDirectories: true)
        let input = rec.appendingPathComponent("demo.opus"); try Data([1]).write(to: input)
        var cfg = Config()
        cfg.recordingsDir = rec.path; cfg.notesDir = root.appendingPathComponent("notes").path
        cfg.workDir = root.appendingPathComponent("work").path
        cfg.transcribe.replacements = [ReplacementRule(from: "wurld", to: "world")]
        let result: [String: Any] = ["segments": [
            ["speaker": "SPEAKER_00", "text": " hello   wurld ", "start": 0.0, "end": 1.0,
             "words": [["word": "hello", "start": 0.0, "end": 0.4], ["word": "wurld", "start": 0.5, "end": 1.0]]],
            ["speaker": "SPEAKER_00", "text": "second", "start": 1.0, "end": 2.0],
            ["speaker": "SPEAKER_01", "text": "reply", "start": 2.0, "end": 3.0],
            ["text": "no speaker", "start": 3.0, "end": 4.0],
        ]]
        let deps = PipelineDeps(
            convertToWav: { _, d in try FileManager.default.createDirectory(at: d.deletingLastPathComponent(), withIntermediateDirectories: true); try Data([0]).write(to: d) },
            transcribe: { _, _ in result }, ollamaReachable: { _ in true },
            summarise: { _, _, _, _ in PipelineTests.validNote }, audioDurationSeconds: { _ in nil })
        let r = await Pipeline.processOne(path: input, config: cfg, deps: deps, stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(r.status, .done)
        let work = URL(fileURLWithPath: cfg.workDir)
        let cached = try String(contentsOf: Pipeline.cachedTranscriptURL(workDir: work, base: r.base), encoding: .utf8)
        let sidecar = try XCTUnwrap(TranscriptSegments.load(workDir: work, base: r.base))
        XCTAssertEqual(TranscriptEditing.renderClean(sidecar) + "\n", cached)
        XCTAssertTrue(cached.contains("hello world"))   // replacement baked in, not re-applied
    }

    // MARK: save / revert

    private func seed(_ root: URL, base: String = "demo") throws {
        let t = sample()
        try t.save(workDir: root, base: base)
        try Data((TranscriptEditing.renderClean(t) + "\n").utf8)
            .write(to: Pipeline.cachedTranscriptURL(workDir: root, base: base))
    }
    private func data(_ u: URL) -> Data? { try? Data(contentsOf: u) }

    func testSaveWritesBothFilesKeepsPristineOnceAndRevertRestores() throws {
        let work = try tmp(); try seed(work)
        let segURL = TranscriptSegments.url(workDir: work, base: "demo")
        let cleanURL = Pipeline.cachedTranscriptURL(workDir: work, base: "demo")
        let origSeg = data(segURL)!, origClean = data(cleanURL)!

        let e1 = TranscriptEditing.applyEdits([0: SegmentEdit(text: "hello bold world")], to: sample())
        try TranscriptEditStore.save(e1, workDir: work, base: "demo")
        XCTAssertEqual(data(TranscriptEditStore.originalSegmentsURL(workDir: work, base: "demo")), origSeg)
        XCTAssertEqual(data(TranscriptEditStore.originalCleanURL(workDir: work, base: "demo")), origClean)
        XCTAssertTrue(try XCTUnwrap(String(data: data(cleanURL)!, encoding: .utf8)).contains("hello bold world"))
        XCTAssertEqual(TranscriptSegments.load(workDir: work, base: "demo")?.segments[0].text, "hello bold world")
        XCTAssertTrue(TranscriptEditStore.isModified(workDir: work, base: "demo"))

        // A second edit never overwrites the pristine copy.
        let e2 = TranscriptEditing.applyEdits([0: SegmentEdit(text: "again")], to: e1)
        try TranscriptEditStore.save(e2, workDir: work, base: "demo")
        XCTAssertEqual(data(TranscriptEditStore.originalSegmentsURL(workDir: work, base: "demo")), origSeg)

        try TranscriptEditStore.revert(workDir: work, base: "demo")
        XCTAssertEqual(data(segURL), origSeg)
        XCTAssertEqual(data(cleanURL), origClean)
        XCTAssertFalse(TranscriptEditStore.isModified(workDir: work, base: "demo"))
        XCTAssertTrue(TranscriptEditStore.hasOriginal(workDir: work, base: "demo"))
    }

    func testSaveFailureLeavesEverythingUntouched() throws {
        let work = try tmp(); try seed(work)
        let segURL = TranscriptSegments.url(workDir: work, base: "demo")
        let cleanURL = Pipeline.cachedTranscriptURL(workDir: work, base: "demo")
        let before = (data(segURL), data(cleanURL))
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: work.path))

        struct Boom: Error {}
        // Fail on the LAST write (the clean transcript) so earlier writes must be rolled back.
        let failing: TranscriptEditStore.Writer = { d, u in
            if u.lastPathComponent == "demo.transcript.clean.txt" { throw Boom() }
            try d.write(to: u, options: .atomic)
        }
        let edited = TranscriptEditing.applyEdits([0: SegmentEdit(text: "changed")], to: sample())
        XCTAssertThrowsError(try TranscriptEditStore.save(edited, workDir: work, base: "demo", writer: failing))
        XCTAssertEqual(data(segURL), before.0)
        XCTAssertEqual(data(cleanURL), before.1)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: work.path)), names)   // no orig files left
        XCTAssertFalse(TranscriptEditStore.hasOriginal(workDir: work, base: "demo"))
    }

    func testSaveWithoutSidecarFailsAndRevertWithoutOriginalFails() throws {
        let work = try tmp()
        XCTAssertThrowsError(try TranscriptEditStore.save(sample(), workDir: work, base: "nope"))
        XCTAssertThrowsError(try TranscriptEditStore.revert(workDir: work, base: "nope"))
    }

    func testOriginalsAreInvisibleToSearchSuffixAndRemovedOnRerun() throws {
        let work = try tmp(); try seed(work)
        try TranscriptEditStore.save(TranscriptEditing.applyEdits([0: SegmentEdit(text: "x")], to: sample()), workDir: work, base: "demo")
        let origClean = TranscriptEditStore.originalCleanURL(workDir: work, base: "demo").lastPathComponent
        XCTAssertFalse(origClean.hasSuffix(".transcript.clean.txt"))
        TranscriptEditStore.removeOriginals(workDir: work, base: "demo")
        XCTAssertFalse(TranscriptEditStore.hasOriginal(workDir: work, base: "demo"))
    }

    // MARK: regenerate after an edit

    func testRegenerateSendsEditedTranscriptToTheSummariser() async throws {
        let root = try tmp()
        var cfg = Config()
        cfg.recordingsDir = root.appendingPathComponent("recordings").path
        cfg.notesDir = root.appendingPathComponent("notes").path
        cfg.workDir = root.appendingPathComponent("work").path
        let work = URL(fileURLWithPath: cfg.workDir), notes = URL(fileURLWithPath: cfg.notesDir)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try seed(work)
        try "# Meeting notes\n\nOLD".write(to: notes.appendingPathComponent("demo.md"), atomically: true, encoding: .utf8)

        try TranscriptEditStore.save(TranscriptEditing.applyEdits([0: SegmentEdit(text: "corrected sentence")], to: sample()),
                                     workDir: work, base: "demo")
        final class Box: @unchecked Sendable { var seen: String? }
        let box = Box()
        let deps = PipelineDeps(
            convertToWav: { _, _ in }, transcribe: { _, _ in [:] }, ollamaReachable: { _ in true },
            summarise: { transcript, _, _, _ in box.seen = transcript; return PipelineTests.validNote })
        let r = await Pipeline.regenerate(base: "demo", options: .init(), config: cfg, deps: deps)
        XCTAssertEqual(r.status, .done, r.message)
        XCTAssertTrue(box.seen?.contains("corrected sentence") == true)
        XCTAssertFalse(box.seen?.contains("brave") == true)
        let backups = try FileManager.default.contentsOfDirectory(atPath: notes.path).filter { NoteVersions.isBackupName($0) }
        XCTAssertEqual(backups.count, 1)
    }
}
