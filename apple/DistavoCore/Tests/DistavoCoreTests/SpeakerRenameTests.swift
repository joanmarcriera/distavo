import XCTest
@testable import DistavoCore

/// Vikunja #2944 phase 1: renaming speakers across note, cached transcript and
/// timed sidecar, atomically, with a composable mapping sidecar.
final class SpeakerRenameTests: XCTestCase {

    private let note = "# Meeting\n\nSPEAKER_00 opened. SPEAKER_01 agreed; SPEAKER_10 (not them) objected.\n"
    private let transcript = "[SPEAKER_00]\nHello there, thanks for joining.\n\n[SPEAKER_01]\nGood to be here.\n\n[SPEAKER_00]\nLet us begin."

    private func segs() -> TranscriptSegments {
        TranscriptSegments(segments: [
            .init(start: 0, end: 2, text: "Hello there, thanks for joining.", speaker: "SPEAKER_00",
                  words: [.init(word: "Hello", start: 0, end: 1, speaker: "SPEAKER_00")]),
            .init(start: 2, end: 4, text: "Good to be here.", speaker: "SPEAKER_01"),
        ])
    }

    private func env(note: String? = nil, transcript: String? = nil, segments: TranscriptSegments? = nil)
        throws -> (notes: URL, work: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("distavo-rename-\(UUID().uuidString)")
        let notes = root.appendingPathComponent("notes"), work = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        if let note { try note.write(to: notes.appendingPathComponent("demo.md"), atomically: true, encoding: .utf8) }
        if let transcript { try transcript.write(to: Pipeline.cachedTranscriptURL(workDir: work, base: "demo"), atomically: true, encoding: .utf8) }
        try segments?.save(workDir: work, base: "demo")
        return (notes, work)
    }

    private func read(_ u: URL) -> String? { try? String(contentsOf: u, encoding: .utf8) }
    private func leftovers(_ dirs: URL...) -> [String] {
        dirs.flatMap { (try? FileManager.default.contentsOfDirectory(atPath: $0.path)) ?? [] }
            .filter { $0.contains("rename-tmp") || $0.contains("rename-orig") }
    }
    private func backups(_ notes: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: notes.path).filter(NoteVersions.isBackupName)
    }

    // MARK: detection

    func testDetectCountsTurnsAndSamples() {
        let found = SpeakerRename.detectSpeakers(note: note, transcript: transcript, segments: segs())
        XCTAssertEqual(found.map(\.label), ["SPEAKER_00", "SPEAKER_01", "SPEAKER_10"])
        XCTAssertEqual(found[0].turns, 2)
        XCTAssertEqual(found[1].turns, 1)
        XCTAssertEqual(found[0].sample, "Hello there, thanks for joining.")
    }

    func testDetectFromSegmentsOnlyAndNoteOnly() {
        let s = SpeakerRename.detectSpeakers(note: nil, transcript: nil, segments: segs())
        XCTAssertEqual(s.map(\.label), ["SPEAKER_00", "SPEAKER_01"])
        XCTAssertEqual(s[0].turns, 1)
        let n = SpeakerRename.detectSpeakers(note: note, transcript: nil, segments: nil)
        XCTAssertEqual(n.map(\.label), ["SPEAKER_00", "SPEAKER_01", "SPEAKER_10"])
    }

    func testDetectIgnoresUnknownAndLongSamplesAreShort() {
        let long = String(repeating: "word ", count: 80)
        let t = "[SPEAKER_UNKNOWN]\nx\n\n[Alice]\n\(long)"
        let found = SpeakerRename.detectSpeakers(note: nil, transcript: t, segments: nil)
        XCTAssertEqual(found.map(\.label), ["Alice"])
        XCTAssertLessThanOrEqual(found[0].sample.count, 90)
    }

    // MARK: rewriting

    func testWholeTokenOnly() {
        let out = SpeakerRename.rewriteNote("SPEAKER_1 and SPEAKER_10, xSPEAKER_1, SPEAKER_1.", mapping: ["SPEAKER_1": "Ann"])
        XCTAssertEqual(out, "Ann and SPEAKER_10, xSPEAKER_1, Ann.")
    }

    func testMetacharactersAreLiteral() {
        let out = SpeakerRename.rewriteNote("**Dr. Smith (CEO):** spoke. Dr Smith no.", mapping: ["Dr. Smith (CEO)": "Bob $1 \\0"])
        XCTAssertEqual(out, "**Bob $1 \\0:** spoke. Dr Smith no.")
    }

    func testSwapIsSimultaneous() throws {
        let m = try SpeakerRename.normalised(["A": "B", "B": "A"])
        XCTAssertEqual(SpeakerRename.rewriteNote("- **A:** hi\n- **B:** yo", mapping: m), "- **B:** hi\n- **A:** yo")
    }

    func testEmptyAndMalformedNamesRejected() {
        XCTAssertThrowsError(try SpeakerRename.normalised(["SPEAKER_00": "   "])) {
            XCTAssertEqual($0 as? SpeakerRenameError, .emptyName("SPEAKER_00"))
        }
        XCTAssertThrowsError(try SpeakerRename.normalised(["SPEAKER_00": "a\nb"]))
        XCTAssertThrowsError(try SpeakerRename.normalised(["SPEAKER_00": "[x]"]))
        XCTAssertEqual(try SpeakerRename.normalised(["SPEAKER_00": "  Ann "]), ["SPEAKER_00": "Ann"])
        XCTAssertEqual(try SpeakerRename.normalised(["SPEAKER_00": "SPEAKER_00"]), [:])
    }

    // MARK: apply

    func testApplyRewritesAllThreeFilesAndStoresMapping() throws {
        let (notes, work) = try env(note: note, transcript: transcript, segments: segs())
        let r = try SpeakerRename.apply(mapping: ["SPEAKER_00": "Marc", "SPEAKER_01": "Edward"],
                                        base: "demo", notesDir: notes, workDir: work)
        XCTAssertEqual(read(notes.appendingPathComponent("demo.md")),
                       "# Meeting\n\nMarc opened. Edward agreed; SPEAKER_10 (not them) objected.\n")
        let t = read(Pipeline.cachedTranscriptURL(workDir: work, base: "demo"))!
        XCTAssertTrue(t.contains("[Marc]\nHello there") && t.contains("[Edward]") && !t.contains("SPEAKER_0"))
        let s = TranscriptSegments.load(workDir: work, base: "demo")!
        XCTAssertEqual(s.segments.map(\.speaker), ["Marc", "Edward"])
        XCTAssertEqual(s.segments[0].words?[0].speaker, "Marc")
        XCTAssertEqual(SpeakerNames.load(workDir: work, base: "demo")?.names, ["SPEAKER_00": "Marc", "SPEAKER_01": "Edward"])
        // One backup of the original note, ignored by scanners.
        let backup = try XCTUnwrap(r.backup)
        XCTAssertTrue(NoteVersions.isBackupName(backup.lastPathComponent))
        XCTAssertEqual(read(backup), note)
        XCTAssertTrue(leftovers(notes, work).isEmpty)
    }

    func testReapplyIsIdempotentAndWritesNothing() throws {
        let (notes, work) = try env(note: note, transcript: transcript, segments: segs())
        try SpeakerRename.apply(mapping: ["SPEAKER_00": "Marc"], base: "demo", notesDir: notes, workDir: work)
        let r = try SpeakerRename.apply(mapping: ["SPEAKER_00": "Marc"], base: "demo", notesDir: notes, workDir: work)
        XCTAssertEqual(r.changedFiles, [])
        XCTAssertNil(r.backup)
        XCTAssertEqual(try backups(notes).count, 1)
    }

    func testRepeatedRenamesComposeAndOriginalsStayRecoverable() throws {
        let (notes, work) = try env(note: note, transcript: transcript, segments: segs())
        try SpeakerRename.apply(mapping: ["SPEAKER_00": "Marc"], base: "demo", notesDir: notes, workDir: work)
        try SpeakerRename.apply(mapping: ["Marc": "Marc R."], base: "demo", notesDir: notes, workDir: work)
        XCTAssertEqual(SpeakerNames.load(workDir: work, base: "demo")?.names, ["SPEAKER_00": "Marc R."])
        // Prose mentions are not label positions, so only the transcript header follows.
        XCTAssertTrue(read(Pipeline.cachedTranscriptURL(workDir: work, base: "demo"))!.contains("[Marc R.]"))
        XCTAssertTrue(read(notes.appendingPathComponent("demo.md"))!.contains("Marc opened"))
    }

    func testMergeIntoExistingLabel() throws {
        let (notes, work) = try env(note: note, transcript: transcript, segments: segs())
        try SpeakerRename.apply(mapping: ["SPEAKER_01": "SPEAKER_00"], base: "demo", notesDir: notes, workDir: work)
        let s = TranscriptSegments.load(workDir: work, base: "demo")!
        XCTAssertEqual(s.segments.map(\.speaker), ["SPEAKER_00", "SPEAKER_00"])
        // A later rename of the merged name moves both originals.
        try SpeakerRename.apply(mapping: ["SPEAKER_00": "Pat"], base: "demo", notesDir: notes, workDir: work)
        XCTAssertEqual(SpeakerNames.load(workDir: work, base: "demo")?.names,
                       ["SPEAKER_00": "Pat", "SPEAKER_01": "Pat"])
    }

    func testSwapInOneOperation() throws {
        let (notes, work) = try env(note: note, transcript: transcript, segments: segs())
        try SpeakerRename.apply(mapping: ["SPEAKER_00": "SPEAKER_01", "SPEAKER_01": "SPEAKER_00"],
                                base: "demo", notesDir: notes, workDir: work)
        XCTAssertTrue(read(notes.appendingPathComponent("demo.md"))!
            .hasPrefix("# Meeting\n\nSPEAKER_01 opened. SPEAKER_00 agreed;"))
        XCTAssertEqual(TranscriptSegments.load(workDir: work, base: "demo")!.segments.map(\.speaker),
                       ["SPEAKER_01", "SPEAKER_00"])
    }

    func testMissingOptionalFilesAreSkipped() throws {
        let (notes, work) = try env(note: note)   // no transcript, no segments
        let r = try SpeakerRename.apply(mapping: ["SPEAKER_00": "Marc"], base: "demo", notesDir: notes, workDir: work)
        XCTAssertEqual(Set(r.changedFiles), ["demo.md", "demo.speaker-names.json"])
        let (n2, w2) = try env(transcript: transcript)   // no note
        XCTAssertNoThrow(try SpeakerRename.apply(mapping: ["SPEAKER_00": "Marc"], base: "demo", notesDir: n2, workDir: w2))
        let (n3, w3) = try env()
        XCTAssertThrowsError(try SpeakerRename.apply(mapping: ["SPEAKER_00": "Marc"], base: "demo", notesDir: n3, workDir: w3))
    }

    func testHandEditedNoteIsRewrittenFromItsCurrentContent() throws {
        let edited = note + "\nMy own addition about SPEAKER_00.\n"
        let (notes, work) = try env(note: edited, transcript: transcript)
        try SpeakerRename.apply(mapping: ["SPEAKER_00": "Marc"], base: "demo", notesDir: notes, workDir: work)
        XCTAssertTrue(read(notes.appendingPathComponent("demo.md"))!.hasSuffix("My own addition about Marc.\n"))
    }

    func testFailureMidCommitLeavesEverythingAsItWas() throws {
        let (notes, work) = try env(note: note, transcript: transcript, segments: segs())
        let segURL = TranscriptSegments.url(workDir: work, base: "demo")
        let segBefore = try Data(contentsOf: segURL)
        // Moves via the seam: transcript aside (1), transcript in (2), segments aside (3),
        // segments in (4) fails. The note was already committed through NoteVersions.
        var moves = 0
        XCTAssertThrowsError(try SpeakerRename.apply(
            mapping: ["SPEAKER_00": "Marc"], base: "demo", notesDir: notes, workDir: work,
            moveItem: { a, b in
                moves += 1
                if moves == 4 { throw CocoaError(.fileWriteNoPermission) }
                try FileManager.default.moveItem(at: a, to: b)
            }))
        XCTAssertEqual(read(notes.appendingPathComponent("demo.md")), note)
        XCTAssertEqual(read(Pipeline.cachedTranscriptURL(workDir: work, base: "demo")), transcript)
        XCTAssertEqual(try Data(contentsOf: segURL), segBefore)
        XCTAssertNil(SpeakerNames.load(workDir: work, base: "demo"))
        XCTAssertTrue(leftovers(notes, work).isEmpty)
        XCTAssertTrue(try backups(notes).isEmpty, "a rolled-back rename leaves no stray backup")
    }

    // MARK: flows into regenerate

    func testRenamedSpeakersFlowIntoRegenerate() async throws {
        let (notes, work) = try env(note: note, transcript: transcript)
        try SpeakerRename.apply(mapping: ["SPEAKER_00": "Marc"], base: "demo", notesDir: notes, workDir: work)
        var cfg = Config()
        cfg.notesDir = notes.path; cfg.workDir = work.path
        cfg.recordingsDir = notes.deletingLastPathComponent().appendingPathComponent("rec").path
        final class Box: @unchecked Sendable { var seen = "" }
        let box = Box()
        let deps = PipelineDeps(
            convertToWav: { _, _ in }, transcribe: { _, _ in [:] }, ollamaReachable: { _ in true },
            summarise: { transcript, _, _, _ in box.seen = transcript; return PipelineTests.validNote })
        let r = await Pipeline.regenerate(base: "demo", options: .init(), config: cfg, deps: deps)
        XCTAssertEqual(r.status, .done, r.message)
        XCTAssertTrue(box.seen.contains("[Marc]") && !box.seen.contains("[SPEAKER_00]"))
    }

    // MARK: narrow matching rule (review round)

    private func rw(_ t: String, _ m: [String: String]) -> String {
        SpeakerRename.rewriteNote(t, mapping: (try? SpeakerRename.normalised(m)) ?? m)
    }

    func testProseMentionOfAHumanNameIsNotRewritten() {
        // "Will" -> "Will Smith" must not turn "Will you join?" into "Will Smith you join?".
        let t = "## Speakers\n- Will — the host\n\nWill you join? Ask Will about it.\n- **Will:** agreed\n"
        XCTAssertEqual(rw(t, ["Will": "Will Smith"]),
                       "## Speakers\n- Will Smith — the host\n\nWill you join? Ask Will about it.\n- **Will Smith:** agreed\n")
    }

    func testRenameToNameContainingOldIsIdempotent() {
        let t = "## Speakers\n- Anna — lead\n\n**Anna:** hello (Anna) owner: Anna\n"
        let once = rw(t, ["Anna": "Anna Puig"])
        XCTAssertEqual(once, "## Speakers\n- Anna Puig — lead\n\n**Anna Puig:** hello (Anna Puig) owner: Anna Puig\n")
        XCTAssertEqual(rw(once, ["Anna": "Anna Puig"]), once, "second application must change nothing")
    }

    func testDiariserLabelsReplacedEverywhereExceptCodeUrlsAndFooter() {
        let footer = "\n\n---\n_Transcribed on this Mac with WhisperKit; SPEAKER_00 labels from SpeakerKit._"
        let t = "# Meeting with SPEAKER_00\n\nSPEAKER_00 said `SPEAKER_00` see https://x.example/SPEAKER_00/a and [l](http://x/SPEAKER_00).\n```\nSPEAKER_00 code\n```\nSpeaker 0 and Speaker_00 too." + footer
        XCTAssertEqual(rw(t, ["SPEAKER_00": "Marc"]),
                       "# Meeting with Marc\n\nMarc said `SPEAKER_00` see https://x.example/SPEAKER_00/a and [l](http://x/SPEAKER_00).\n```\nSPEAKER_00 code\n```\nMarc and Marc too." + footer)
    }

    func testHumanNamesNotRewrittenInTitleUrlCodeFooterOrNoteOwnerLine() {
        let footer = "\n\n---\n_Transcribed on this Mac with X (Will)._"
        let t = "# Will's meeting\n\nNote owner: Will\n**Link:** https://will.example/Will:\nUse `Will:` here.\n```\nWill: x\n```" + footer
        XCTAssertEqual(rw(t, ["Will": "Will Smith"]), t)
    }

    func testLabelPositionsInSpeakersSectionAttributionsOwnerFieldsAndTables() {
        let t = "## Speakers\n- **Marc** — owner\n* Edward (Cambridge)\n1. Núria: interviewer\n\n## Action items\n| Action | Owner | Deadline |\n|---|---|---|\n| Send CV | Marc | Friday |\n| Marc to call | Edward | none |\n\nEvidence (Marc, 00:10). Task owner: Marc.\n"
        let expected = "## Speakers\n- **Marc R.** — owner\n* Ed (Cambridge)\n1. Núria: interviewer\n\n## Action items\n| Action | Owner | Deadline |\n|---|---|---|\n| Send CV | Marc R. | Friday |\n| Marc to call | Ed | none |\n\nEvidence (Marc R., 00:10). Task owner: Marc R..\n"
        XCTAssertEqual(rw(t, ["Marc": "Marc R.", "Edward": "Ed"]), expected)
    }

    func testTranscriptRenamesOnlyHeadersNeverSpokenText() {
        let t = "[Will]\nWill you join? [Will] said so.\n\n[SPEAKER_01]\n[Will]\n\n[Will]\nok"
        let out = SpeakerRename.rewriteTranscript(t, mapping: ["Will": "Will Smith"])
        XCTAssertEqual(out, "[Will Smith]\nWill you join? [Will] said so.\n\n[SPEAKER_01]\n[Will]\n\n[Will Smith]\nok")
    }

    func testSegmentsTextIsNeverRewritten() {
        let s = TranscriptSegments(segments: [.init(start: 0, end: 1, text: "Will you join?", speaker: "Will")])
        let out = SpeakerRename.rewrite(s, mapping: ["Will": "Will Smith"])
        XCTAssertEqual(out.segments[0].text, "Will you join?")
        XCTAssertEqual(out.segments[0].speaker, "Will Smith")
    }

    // MARK: failure and safety

    func testUnreadableNoteThrowsAndChangesNothing() throws {
        let (notes, work) = try env(transcript: transcript, segments: segs())
        try Data([0xFF, 0xFE, 0x80, 0x81]).write(to: notes.appendingPathComponent("demo.md"))
        XCTAssertThrowsError(try SpeakerRename.apply(mapping: ["SPEAKER_00": "Marc"], base: "demo", notesDir: notes, workDir: work)) {
            XCTAssertEqual($0 as? SpeakerRenameError, .unreadable("demo.md"))
        }
        XCTAssertEqual(read(Pipeline.cachedTranscriptURL(workDir: work, base: "demo")), transcript)
        XCTAssertEqual(TranscriptSegments.load(workDir: work, base: "demo")?.segments.first?.speaker, "SPEAKER_00")
        XCTAssertNil(SpeakerNames.load(workDir: work, base: "demo"))
    }

    func testNewerSidecarRefusedCorruptOneMovedAside() throws {
        let (notes, work) = try env(note: note, transcript: transcript)
        let names = SpeakerNames.url(workDir: work, base: "demo")
        try #"{"version": 99, "names": {}}"#.write(to: names, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try SpeakerRename.apply(mapping: ["SPEAKER_00": "Marc"], base: "demo", notesDir: notes, workDir: work)) {
            XCTAssertEqual($0 as? SpeakerRenameError, .newerSidecar(99))
        }
        XCTAssertEqual(read(notes.appendingPathComponent("demo.md")), note)
        XCTAssertEqual(read(names), #"{"version": 99, "names": {}}"#)

        try "not json".write(to: names, atomically: true, encoding: .utf8)
        try SpeakerRename.apply(mapping: ["SPEAKER_00": "Marc"], base: "demo", notesDir: notes, workDir: work)
        XCTAssertEqual(SpeakerNames.load(workDir: work, base: "demo")?.names, ["SPEAKER_00": "Marc"])
        let corrupt = try FileManager.default.contentsOfDirectory(atPath: work.path).filter { $0.contains(".corrupt-") }
        XCTAssertEqual(corrupt.count, 1)
        XCTAssertEqual(read(work.appendingPathComponent(corrupt[0])), "not json")
    }

    func testDecomposedUnicodeNamesAreRenamedAndOtherBytesPreserved() throws {
        let nfd = "Nu\u{0301}ria"
        let nfc = "N\u{00FA}ria"
        let t = "- **\(nfd):** hola\n- Cafe\u{0301} stays NFD\n"
        let out = SpeakerRename.rewriteNote(t, mapping: try SpeakerRename.normalised([nfc: "Núria Puig"]))
        XCTAssertEqual(out, "- **Núria Puig:** hola\n- Cafe\u{0301} stays NFD\n")
        let tr = SpeakerRename.rewriteTranscript("[\(nfd)]\nhola", mapping: try SpeakerRename.normalised([nfc: "N"]))
        XCTAssertEqual(tr, "[N]\nhola")
        let found = SpeakerRename.detectSpeakers(note: nil, transcript: "[\(nfd)]\nx\n\n[\(nfc)]\ny", segments: nil)
        XCTAssertEqual(found.count, 1)
    }

    func testMergeKeepsPreMergeCopiesAndIsReported() throws {
        let (notes, work) = try env(note: note, transcript: transcript, segments: segs())
        let m = try SpeakerRename.normalised(["SPEAKER_01": "SPEAKER_00"])
        let merges = SpeakerRename.merges(m, present: ["SPEAKER_00", "SPEAKER_01"])
        XCTAssertEqual(merges.count, 1)
        XCTAssertEqual(merges[0].from, ["SPEAKER_01"])
        XCTAssertEqual(merges[0].into, "SPEAKER_00")
        XCTAssertTrue(SpeakerRename.merges(["SPEAKER_00": "Ann"], present: ["SPEAKER_00", "SPEAKER_01"]).isEmpty)
        XCTAssertTrue(SpeakerRename.merges(["A": "B", "B": "A"], present: ["A", "B"]).isEmpty, "a swap is not a merge")
        try SpeakerRename.apply(mapping: ["SPEAKER_01": "SPEAKER_00"], base: "demo", notesDir: notes, workDir: work)
        let files = try FileManager.default.contentsOfDirectory(atPath: work.path).filter { $0.contains(".pre-merge-") }
        XCTAssertEqual(files.count, 2)
        let tCopy = try XCTUnwrap(files.first { $0.hasPrefix("demo.transcript.clean.txt") })
        XCTAssertEqual(read(work.appendingPathComponent(tCopy)), transcript)
        // Plain renames keep no extra copies.
        let (n2, w2) = try env(note: note, transcript: transcript, segments: segs())
        try SpeakerRename.apply(mapping: ["SPEAKER_00": "Marc"], base: "demo", notesDir: n2, workDir: w2)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: w2.path).filter { $0.contains(".pre-merge-") }.isEmpty)
    }

    func testResetToOriginalLabels() throws {
        let (notes, work) = try env(note: note, transcript: transcript, segments: segs())
        try SpeakerRename.apply(mapping: ["SPEAKER_00": "Marc", "SPEAKER_01": "Edward"], base: "demo", notesDir: notes, workDir: work)
        let reset = SpeakerRename.resetMapping(workDir: work, base: "demo")
        XCTAssertEqual(reset, ["Marc": "SPEAKER_00", "Edward": "SPEAKER_01"])
        try SpeakerRename.apply(mapping: reset, base: "demo", notesDir: notes, workDir: work)
        XCTAssertEqual(read(Pipeline.cachedTranscriptURL(workDir: work, base: "demo")), transcript)
        XCTAssertEqual(TranscriptSegments.load(workDir: work, base: "demo")?.segments.map(\.speaker), ["SPEAKER_00", "SPEAKER_01"])
        XCTAssertEqual(SpeakerNames.load(workDir: work, base: "demo")?.names, [:])
        // A merged speaker cannot be reset.
        try SpeakerRename.apply(mapping: ["SPEAKER_01": "SPEAKER_00"], base: "demo", notesDir: notes, workDir: work)
        XCTAssertTrue(SpeakerRename.resetMapping(workDir: work, base: "demo").isEmpty)
    }

    func testPermissionsSurviveAndNoTempsRemain() throws {
        let (notes, work) = try env(note: note, transcript: transcript, segments: segs())
        let n = notes.appendingPathComponent("demo.md")
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: n.path)
        try SpeakerRename.apply(mapping: ["SPEAKER_00": "Marc"], base: "demo", notesDir: notes, workDir: work)
        let perms = try FileManager.default.attributesOfItem(atPath: n.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o640)
        XCTAssertTrue(leftovers(notes, work).isEmpty)
    }

    func testRegenerateUsesRenamedOwnerLabelAndExplainsRenames() async throws {
        let (notes, work) = try env(note: note, transcript: transcript)
        try SpeakerRename.apply(mapping: ["SPEAKER_01": "Marc"], base: "demo", notesDir: notes, workDir: work)
        var cfg = Config()
        cfg.notesDir = notes.path; cfg.workDir = work.path
        cfg.recordingsDir = notes.deletingLastPathComponent().appendingPathComponent("rec").path
        cfg.userSpeaker = "SPEAKER_01"
        final class Box: @unchecked Sendable { var ctx: NoteContext? }
        let box = Box()
        let deps = PipelineDeps(
            convertToWav: { _, _ in }, transcribe: { _, _ in [:] }, ollamaReachable: { _ in true },
            summarise: { _, _, _, c in box.ctx = c; return PipelineTests.validNote })
        let r = await Pipeline.regenerate(base: "demo", options: .init(), config: cfg, deps: deps)
        XCTAssertEqual(r.status, .done, r.message)
        XCTAssertEqual(box.ctx?.userSpeaker, "Marc")
        XCTAssertTrue(box.ctx?.participants?.contains("SPEAKER_01 is now \"Marc\"") == true)
        XCTAssertEqual(cfg.userSpeaker, "SPEAKER_01", "config is never touched")
        // A recording that was not renamed is unchanged.
        let plain = SpeakerNames.regenerateContext(userSpeaker: "SPEAKER_00", participants: "x", workDir: work, base: "other")
        XCTAssertEqual(plain.userSpeaker, "SPEAKER_00")
        XCTAssertEqual(plain.participants, "x")
    }
}
