import XCTest
@testable import DistavoCore

/// `NoteWarnings` (D082/D081): warnings at the top of the note. Synthetic notes only.
final class NoteWarningsTests: XCTestCase {
    private let body = "# Garden planning call\n\n## Summary\nTrees arrive Thursday.\n\n## Action items\n- Oskar asks two suppliers\n"

    func testNoWarningMeansNoBlockAndByteIdentical() {
        XCTAssertEqual(NoteWarnings.insert(NoteWarnings.bullets(.init()), into: body), body)
    }

    func testTruncatedOnlyGivesOneBullet() {
        let out = NoteWarnings.insert(NoteWarnings.bullets(.init(truncated: true)), into: body)
        let bullets = out.components(separatedBy: "\n").filter { $0.hasPrefix("> - ") }
        XCTAssertEqual(bullets.count, 1)
        XCTAssertTrue(out.contains(NoteWarnings.header))
        XCTAssertTrue(bullets[0].contains("stopped before the call ended"))
    }

    func testThreeWarningsInFixedOrder() {
        let s = NoteWarnings.Signals(truncated: true, wordsRemoved: 2, nameGroups: [["Petra Holm", "Petra Holme"]],
                                     unsureLanguage: nil)
        let bullets = NoteWarnings.bullets(s)
        XCTAssertEqual(bullets.count, 3)
        XCTAssertTrue(bullets[0].contains("stopped before"))
        XCTAssertTrue(bullets[1].hasPrefix("2 words"))
        XCTAssertTrue(bullets[2].contains("Petra Holm / Petra Holme"))
        // Same order whatever the field order: unsure language is always last.
        let four = NoteWarnings.bullets(.init(truncated: true, wordsRemoved: 1, nameGroups: [["A", "B"]],
                                              unsureLanguage: "English 43%"))
        XCTAssertTrue(four[3].hasPrefix("Language detection was unsure (English 43%)"))
    }

    func testBlockSitsAfterTitle() {
        let out = NoteWarnings.insert(["One"], into: body)
        XCTAssertEqual(out, "# Garden planning call\n\n> [!warning] Check this note\n> - One\n\n## Summary\nTrees arrive Thursday.\n\n## Action items\n- Oskar asks two suppliers\n")
    }

    func testBlockSitsAfterFrontmatterNeverBefore() {
        let note = "---\ndate: 2026-11-18\ntags: [meeting]\n---\n# Garden planning call\n\nText\n"
        let out = NoteWarnings.insert(["One"], into: note)
        XCTAssertTrue(out.hasPrefix("---\ndate: 2026-11-18\ntags: [meeting]\n---\n# Garden planning call\n\n> [!warning] Check this note\n> - One\n\nText\n"), out)
        // No title: right after the frontmatter.
        let untitled = "---\ndate: 2026-11-18\n---\n## Summary\nText\n"
        XCTAssertEqual(NoteWarnings.insert(["One"], into: untitled),
                       "---\ndate: 2026-11-18\n---\n> [!warning] Check this note\n> - One\n\n## Summary\nText\n")
    }

    func testReinsertKeepsExactlyOneBlock() {
        let once = NoteWarnings.insert(["One", "Two"], into: body)
        let twice = NoteWarnings.insert(["One", "Two"], into: once)
        XCTAssertEqual(twice, once)
        XCTAssertEqual(twice.components(separatedBy: NoteWarnings.header).count - 1, 1)
        // A regenerate that no longer has warnings removes the block.
        XCTAssertEqual(NoteWarnings.insert([], into: once), body)
    }

    func testUnsureLanguage() {
        XCTAssertEqual(NoteWarnings.unsureLanguage(detections: [("nn", 0.43), ("en", 0.40)]), "Nynorsk 43%")
        XCTAssertNil(NoteWarnings.unsureLanguage(detections: [("en", 0.9), ("nn", 0.43)]))
        XCTAssertNil(NoteWarnings.unsureLanguage(detections: []))
    }

    func testCarriedUnsureLanguageFromThePreviousNote() {
        let old = NoteWarnings.insert(NoteWarnings.bullets(.init(unsureLanguage: "English 43%")), into: body)
        XCTAssertEqual(NoteWarnings.carriedUnsureLanguage(in: old), "English 43%")
        XCTAssertNil(NoteWarnings.carriedUnsureLanguage(in: body))
    }

    func testKeyAbsentIsOffAndFreshInstallOn() throws {
        let old = try JSONDecoder().decode(NotesConfig.self, from: Data("{}".utf8))
        XCTAssertFalse(old.warningsOnTop)
        XCTAssertTrue(Config.recommendedForThisMac().notes.warningsOnTop)
    }

    func testComposeNoteWithKeyOffHasNoBlock() {
        var cfg = Config()
        cfg.notes.warningsOnTop = false
        let out = Pipeline.composeNote(body: body, footer: "\n_footer_\n", meta: nil, config: cfg,
                                       context: NoteContext(noteOwner: "Me", userSpeaker: "SPEAKER_00"), sourceName: nil, timed: nil, cleanTranscript: "",
                                       dominantCode: nil, existingNote: nil,
                                       warnings: .init(truncated: true))
        XCTAssertEqual(out, body + "\n_footer_\n")
        cfg.notes.warningsOnTop = true
        let on = Pipeline.composeNote(body: body, footer: "\n_footer_\n", meta: nil, config: cfg,
                                      context: NoteContext(noteOwner: "Me", userSpeaker: "SPEAKER_00"), sourceName: nil, timed: nil, cleanTranscript: "",
                                      dominantCode: nil, existingNote: nil,
                                      warnings: .init(truncated: true))
        XCTAssertTrue(on.contains(NoteWarnings.header))
        XCTAssertTrue(on.hasSuffix("\n_footer_\n"))
    }
    /// A2: processOne end to end, a recording cut mid-sentence: the block sits above the first "##".
    func testPipelinePutsTheTruncationWarningAboveTheFirstSection() async throws {
        func run(warningsOnTop: Bool) async throws -> String {
            let root = TestTemp.root.appendingPathComponent("distavo-warn-\(UUID().uuidString)")
            let rec = root.appendingPathComponent("recordings")
            try FileManager.default.createDirectory(at: rec, withIntermediateDirectories: true)
            let input = rec.appendingPathComponent("garden.opus")
            try Data([0, 1, 2, 3]).write(to: input)
            var cfg = Config()
            cfg.recordingsDir = rec.path
            cfg.notesDir = root.appendingPathComponent("notes").path
            cfg.workDir = root.appendingPathComponent("work").path
            cfg.notes.warningsOnTop = warningsOnTop
            let result: [String: Any] = ["segments": [
                ["start": 0.0, "end": 60.0, "text": "Good morning, this is the garden planning call.", "speaker": "SPEAKER_00"],
                ["start": 60.0, "end": 119.5, "text": "and the trees arrive on Thursday but the pipes", "speaker": "SPEAKER_01"],
            ]]
            let deps = PipelineDeps(
                convertToWav: { _, dest in
                    try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Data([0]).write(to: dest)
                },
                transcribe: { _, _ in result },
                ollamaReachable: { _ in true },
                summarise: { _, _, _, _ in PipelineTests.validNote },
                audioDurationSeconds: { _ in 120 })
            let r = await Pipeline.processOne(path: input, config: cfg, deps: deps, stableChecks: 1, stableDelay: 0)
            XCTAssertEqual(r.status, .done, r.message)
            return try String(contentsOf: XCTUnwrap(r.notePath), encoding: .utf8)
        }
        let on = try await run(warningsOnTop: true)
        let block = try XCTUnwrap(on.range(of: NoteWarnings.header))
        let firstSection = try XCTUnwrap(on.range(of: "\n## "))
        XCTAssertLessThan(block.lowerBound, firstSection.lowerBound)
        XCTAssertTrue(on.contains("stopped before the call ended"))
        XCTAssertTrue(on.contains(TruncationCheck.banner), "the footer line stays")
        let off = try await run(warningsOnTop: false)
        XCTAssertFalse(off.contains(NoteWarnings.header))
        XCTAssertTrue(off.contains(TruncationCheck.banner))
    }
    /// Review round 1: with "Languages I speak", the bullet never names the language the router ignored.
    func testUnsureLanguageFollowsTheSpokenList() {
        let result: [String: Any] = ["detections": [["code": "nn", "probability": 0.43], ["code": "en", "probability": 0.40]]]
        XCTAssertEqual(NoteWarnings.unsureLanguage(transcribeResult: result), "Nynorsk 43%")
        XCTAssertEqual(NoteWarnings.unsureLanguage(transcribeResult: result, spokenLanguages: ["en", "ca"]), "English 40%")
        XCTAssertNil(NoteWarnings.unsureLanguage(transcribeResult: result, spokenLanguages: ["ca"]))
    }
}
