import XCTest
@testable import DistavoCore

/// Drive 2026-11-23: notes that fit the owner's own days (names glossary, action-item owners, playback and
/// sales-call templates, sales-call export). Synthetic names only.
final class UseDrive1123Tests: XCTestCase {

    // MARK: Names glossary

    func testGlossaryParsesCanonicalNamesAliasesAndComments() {
        let g = NameGlossary.parse("""
        # who and what
        Jordan Ellis: Jordon Ellis, Jordan Elis; Jordan L
        Acme Cooling

        : orphan alias
        """)
        XCTAssertEqual(g.entries.count, 2)
        XCTAssertEqual(g.entries[0].canonical, "Jordan Ellis")
        XCTAssertEqual(g.entries[0].aliases, ["Jordon Ellis", "Jordan Elis", "Jordan L"])
        XCTAssertEqual(g.entries[1].canonical, "Acme Cooling")
        XCTAssertEqual(g.terms, ["Jordan Ellis", "Acme Cooling"])
    }

    func testGlossaryMergesSpellingsWholeWordOnly() {
        let g = NameGlossary.parse("Jordan Ellis: Jordon, Jordan Elis")
        let out = g.apply(to: "Jordon will send it. Ask Jordan Elis. Jordonville is a town.")
        XCTAssertEqual(out.text, "Jordan Ellis will send it. Ask Jordan Ellis. Jordonville is a town.")
        XCTAssertEqual(out.merged, 2)
    }

    func testGlossaryLeavesHighlightsAndFactsLedgerQuotesAlone() {
        let g = NameGlossary.parse("Jordan Ellis: Jordon")
        let note = """
        ## Summary
        Jordon agreed.

        ## Highlights
        > "Jordon said yes"

        ## Facts ledger
        - Jordon: "I will send it"

        ## Next
        Jordon calls back.
        """
        let out = g.apply(to: note).text
        XCTAssertTrue(out.contains("Jordan Ellis agreed."))
        XCTAssertTrue(out.contains("> \"Jordon said yes\""))
        XCTAssertTrue(out.contains("- Jordon: \"I will send it\""))
        XCTAssertTrue(out.contains("Jordan Ellis calls back."))
    }

    func testEmptyGlossaryChangesNothing() {
        let out = NameGlossary.parse("").apply(to: "Jordon here.")
        XCTAssertEqual(out.text, "Jordon here.")
        XCTAssertEqual(out.merged, 0)
    }

    func testGlossaryFileLoadsFromTheSupportFolderAndMissingFileIsEmpty() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertTrue(NameGlossary.load(supportDir: dir).entries.isEmpty)
        try "Jordan Ellis: Jordon\n".write(to: dir.appendingPathComponent(NameGlossary.fileName), atomically: true, encoding: .utf8)
        XCTAssertEqual(NameGlossary.load(supportDir: dir).entries.first?.canonical, "Jordan Ellis")
    }

    func testSummaryChecksAppliesTheGlossaryAndSaysSo() {
        let ctx = NoteContext(noteOwner: "Jordan Ellis", userSpeaker: "SPEAKER_00")
        let g = NameGlossary.parse("Jordan Ellis: Jordon")
        let out = SummaryChecks.apply(summary: "## Summary\nJordon owns it.\n", transcript: "x", context: ctx,
                                      nameCheck: true, nameGlossary: g)
        XCTAssertTrue(out.text.contains("Jordan Ellis owns it."))
        XCTAssertTrue(out.notes.contains { $0.contains("1") && $0.lowercased().contains("names glossary") }, "\(out.notes)")
        // Off: untouched.
        let off = SummaryChecks.apply(summary: "## Summary\nJordon owns it.\n", transcript: "x", context: ctx,
                                      nameCheck: false, nameGlossary: g)
        XCTAssertTrue(off.text.contains("Jordon owns it."))
    }

    // MARK: Action-item owners

    func testTaskOwnerKeptWhenTranscriptNamesThem() {
        let transcript = "[SPEAKER_01]\nSam, can you send the quote? Yes, I will send the quote on Friday."
        let note = "- [ ] Send the quote — owner: Sam; due: none\n"
        let r = ActionItemOwners.check(note, transcript: transcript, noteOwner: "Jordan Ellis")
        XCTAssertEqual(r.text, note)
        XCTAssertEqual(r.cleared, 0)
    }

    func testTaskOwnerNeverHeardIsClearedToUnassigned() {
        let transcript = "[SPEAKER_00]\nWe should send the quote this week."
        let note = "- [ ] Send the quote — owner: Priya; due: 2026-11-27\n"
        let r = ActionItemOwners.check(note, transcript: transcript, noteOwner: "Jordan Ellis")
        XCTAssertEqual(r.text, "- [ ] Send the quote — owner: unassigned; due: 2026-11-27\n")
        XCTAssertEqual(r.cleared, 1)
    }

    func testNoteOwnerAndUnassignedAreAlwaysAllowed() {
        let note = "- [ ] A — owner: Jordan Ellis; due: none\n- [ ] B — owner: unassigned; due: none\n- [ ] C — owner: Jordan; due: none\n"
        let r = ActionItemOwners.check(note, transcript: "nothing named", noteOwner: "Jordan Ellis")
        XCTAssertEqual(r.text, note)
    }

    func testTaskOwnerPromptSaysOnlyWhenNamedOnlyWithNameCheck() {
        let on = ActionItemsPrompt.namedOwnerTasksSection.instruction
        XCTAssertTrue(on.contains("only when the transcript names"), on)
        XCTAssertFalse(on.contains("(or the note owner)"))
        // Off (every existing config): the wording is the old one, byte for byte.
        XCTAssertTrue(ActionItemsPrompt.tasksSection.instruction.contains("Name the owner as a person (or the note owner)"))
        let t = ActionItemsPrompt.effectiveTemplate(nil, style: .factsFirst, enabled: true)!
        XCTAssertTrue(t.sections.contains { $0.instruction.contains("(or the note owner)") })
        let n = ActionItemsPrompt.effectiveTemplate(nil, style: .factsFirst, enabled: true, namedOwnersOnly: true)!
        XCTAssertTrue(n.sections.contains { $0.instruction.contains("only when the transcript names") })
    }

    func testMisheardOwnerSurvivesTheGlossaryMerge() {
        let g = NameGlossary.parse("Jordan Ellis: Jordon")
        let ctx = NoteContext(noteOwner: "Me", userSpeaker: "SPEAKER_00")
        let out = SummaryChecks.apply(summary: "## Tasks\n- [ ] Send it — owner: Jordon; due: none\n- [ ] Call — owner: Jordan Ellis; due: none\n",
                                      transcript: "[SPEAKER_01]\nJordon will send it.", context: ctx, nameCheck: true, nameGlossary: g)
        XCTAssertFalse(out.text.contains("unassigned"), out.text)
        XCTAssertEqual(out.text.components(separatedBy: "Jordan Ellis").count - 1, 2)
    }

    func testNoteOwnerFirstNameParticipantsAndAccentsAreNamed() {
        let note = "- [ ] A — owner: Marc; due: none\n- [ ] B — owner: Sam; due: none\n- [ ] C — owner: Marti; due: none\n"
        let r = ActionItemOwners.check(note, transcript: "[SPEAKER_00]\nI will do it. Martí agrees.", noteOwner: "Joan Marc Riera",
                                       participants: "Sam (client)")
        XCTAssertEqual(r.text, note)
        XCTAssertEqual(r.cleared, 0)
    }

    func testAliasThatIsAnOrdinaryWordOnlyMatchesWhenCapitalised() {
        let g = NameGlossary.parse("Marc Riera: Mark")
        XCTAssertEqual(g.apply(to: "Mark it done. Mark said yes.").text, "Marc Riera it done. Marc Riera said yes.")
        XCTAssertEqual(g.apply(to: "please mark it done").text, "please mark it done")
    }

    func testAliasInsideAnotherEntrysNameIsLeftAlone() {
        let g = NameGlossary.parse("Ellis Corp: Ellis\nJordan Ellis: Jordon")
        XCTAssertEqual(g.apply(to: "Jordan Ellis met Ellis.").text, "Jordan Ellis met Ellis Corp.")
    }

    func testSpeakersAndCorrectionsSectionsAreNotRewritten() {
        let g = NameGlossary.parse("Jordan Ellis: Jordon")
        let note = "## Speakers\n- SPEAKER_01: Jordon\n\n## Possible transcription corrections\n- Jordon -> Jordan\n\n## Summary\nJordon spoke.\n"
        let out = g.apply(to: note).text
        XCTAssertTrue(out.contains("- SPEAKER_01: Jordon"))
        XCTAssertTrue(out.contains("- Jordon -> Jordan"))
        XCTAssertTrue(out.contains("Jordan Ellis spoke."))
    }

    func testTwoCallsSameFirmSameDayGetSeparateFolders() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("sy-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let note1 = "## Firm\nAcme\n\nfirst\n", note2 = "## Firm\nAcme\n\nsecond\n"
        guard case .exported(let d1) = SalesCallExport.export(noteText: note1, audio: nil, base: "rec-a", date: Date(), to: root),
              case .exported(let d2) = SalesCallExport.export(noteText: note2, audio: nil, base: "rec-b", date: Date(), to: root),
              case .exported(let d1again) = SalesCallExport.export(noteText: note1 + "x", audio: nil, base: "rec-a", date: Date(), to: root)
        else { return XCTFail("export failed") }
        XCTAssertNotEqual(d1.path, d2.path)
        XCTAssertTrue(d2.lastPathComponent.hasSuffix(" 2"))
        XCTAssertEqual(d1.standardizedFileURL.path, d1again.standardizedFileURL.path)
        XCTAssertTrue(try String(contentsOf: d1.appendingPathComponent("call.md"), encoding: .utf8).contains("first"))
        XCTAssertTrue(try String(contentsOf: d2.appendingPathComponent("call.md"), encoding: .utf8).contains("second"))
    }

    func testRoleWordsAreNotNames() {
        let note = "- [ ] A — owner: the client; due: none\n- [ ] B — owner: Finance team; due: none\n"
        let r = ActionItemOwners.check(note, transcript: "the client said the team should wait", noteOwner: "Jordan Ellis")
        XCTAssertEqual(r.cleared, 2, r.text)
    }

    func testLongerGlossaryNamesAreProtectedFirst() {
        let g = NameGlossary.parse("Jordan\nJordan Ellis\nEllis Corp: Ellis")
        XCTAssertEqual(g.apply(to: "Jordan Ellis met Ellis.").text, "Jordan Ellis met Ellis Corp.")
    }

    func testHandMadeFolderAndAnotherCallsNumberedFolderAreBothRespected() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("sw-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        var comps = DateComponents(); comps.year = 2026; comps.month = 11; comps.day = 23; comps.hour = 10
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let date = cal.date(from: comps)!
        try fm.createDirectory(at: root.appendingPathComponent("2026-11-23-Acme"), withIntermediateDirectories: true)   // by hand
        guard case .exported(let b) = SalesCallExport.export(noteText: "## Firm\nAcme\n\nB\n", audio: nil, base: "rec-b", date: date, to: root, timeZone: cal.timeZone),
              case .exported(let a) = SalesCallExport.export(noteText: "## Firm\nAcme\n\nA\n", audio: nil, base: "rec-a", date: date, to: root, timeZone: cal.timeZone)
        else { return XCTFail() }
        XCTAssertNotEqual(a.path, b.path)
        XCTAssertTrue(try String(contentsOf: b.appendingPathComponent("call.md"), encoding: .utf8).contains("B"))
    }

    func testAFolderMadeByHandIsNeverTakenOver() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("sz-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        var comps = DateComponents(); comps.year = 2026; comps.month = 11; comps.day = 23; comps.hour = 10
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let date = cal.date(from: comps)!
        let mine = root.appendingPathComponent("2026-11-23-Acme")
        try fm.createDirectory(at: mine, withIntermediateDirectories: true)
        try "keep".write(to: mine.appendingPathComponent("call.md"), atomically: true, encoding: .utf8)
        guard case .exported(let d) = SalesCallExport.export(noteText: "## Firm\nAcme\n", audio: nil, base: "rec-a", date: date, to: root, timeZone: cal.timeZone)
        else { return XCTFail() }
        XCTAssertEqual(d.lastPathComponent, "2026-11-23-Acme 2")
        XCTAssertEqual(try String(contentsOf: mine.appendingPathComponent("call.md"), encoding: .utf8), "keep")
    }

    // MARK: Templates

    func testSalesCallLogTemplateHasTheSevenThings() throws {
        let t = try XCTUnwrap(SummaryTemplateCatalog.bundledTemplates.first { $0.id == SummaryTemplateCatalog.salesCallLogID })
        XCTAssertEqual(t.headings, ["## Who", "## Firm", "## What they said about their work", "## Objections raised",
                                    "## Next step and date", "## What we promised", "## Possible transcription corrections"])
        XCTAssertTrue(t.guidance.contains("Do not invent"))
        XCTAssertFalse(SummaryTemplateCatalog.template(id: "sales_call_log", config: Config())!.headings.contains("## Suggested follow-up email"))
    }

    func testPlaybackIsAPickableTemplateWithNoAttendeesOrFollowUp() throws {
        let t = try XCTUnwrap(SummaryTemplateCatalog.template(id: "playback", config: Config()))
        XCTAssertEqual(t.name, "Training playback")
        let all = (t.headings + [t.guidance]).joined(separator: " ").lowercased()
        for banned in ["attendee", "action item", "follow-up email", "participants"] where banned != "participants" {
            XCTAssertFalse(t.headings.joined().lowercased().contains(banned), banned)
        }
        XCTAssertTrue(all.contains("not a live meeting"))
    }

    // MARK: Sales call export

    func testFirmIsReadFromTheFirmSection() {
        let note = "# Call\n\n## Who\nPriya Shah, buyer\n\n## Firm\nAcme Leisure Parks Ltd\n\n## Next step and date\nsend samples\n"
        XCTAssertEqual(SalesCallExport.firm(in: note), "Acme Leisure Parks Ltd")
        XCTAssertNil(SalesCallExport.firm(in: "## Firm\nnone stated\n"))
        XCTAssertNil(SalesCallExport.firm(in: "no sections"))
    }

    func testSalesCallNoteIsRecognisedOnlyBySectionNotWords() {
        XCTAssertTrue(SalesCallExport.isSalesCallNote("## Who\nA\n\n## Firm\nB\n\n## What we promised\nC\n"))
        XCTAssertFalse(SalesCallExport.isSalesCallNote("## Summary\nThe firm said what we promised.\n"))
        XCTAssertFalse(SalesCallExport.isSalesCallNote("## Firm\nB\n"))
    }

    func testNotesWindowOffersTheSalesExportForAnyNote() {
        XCTAssertEqual(NoteAction.exportSalesCall.label, "Export Sales Call…")
        XCTAssertTrue(NoteAction.allCases.contains(.exportSalesCall))
    }

    func testFolderNameIsDatePlusSafeFirm() {
        var comps = DateComponents(); comps.year = 2026; comps.month = 11; comps.day = 23; comps.hour = 10
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Europe/London")!
        let date = cal.date(from: comps)!
        XCTAssertEqual(SalesCallExport.folderName(date: date, firm: "Acme / Leisure: Parks?", timeZone: cal.timeZone),
                       "2026-11-23-Acme Leisure Parks")
        XCTAssertEqual(SalesCallExport.folderName(date: date, firm: nil, timeZone: cal.timeZone), "2026-11-23-unknown-firm")
    }

    func testExportWritesCallMdAndAudioAndIsRepeatable() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("sx-\(UUID().uuidString)")
        let out = root.appendingPathComponent("handoff")
        try fm.createDirectory(at: out, withIntermediateDirectories: true)   // the hand-off root must already exist
        defer { try? fm.removeItem(at: root) }
        let audio = root.appendingPathComponent("rec.m4a"); try Data([1, 2, 3]).write(to: audio)
        let note = "## Firm\nAcme Parks\n\n## Who\nPriya\n"
        var comps = DateComponents(); comps.year = 2026; comps.month = 11; comps.day = 23; comps.hour = 10
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let date = cal.date(from: comps)!

        let r1 = SalesCallExport.export(noteText: note, audio: audio, date: date, to: out, timeZone: cal.timeZone)
        guard case .exported(let dir) = r1 else { return XCTFail("\(r1)") }
        XCTAssertEqual(dir.lastPathComponent, "2026-11-23-Acme Parks")
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("call.md"), encoding: .utf8), note)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("rec.m4a")), Data([1, 2, 3]))
        // Again: same folder, nothing duplicated, call.md refreshed.
        let r2 = SalesCallExport.export(noteText: note + "more\n", audio: audio, date: date, to: out, timeZone: cal.timeZone)
        guard case .exported(let dir2) = r2 else { return XCTFail("\(r2)") }
        XCTAssertEqual(dir2.standardizedFileURL.path, dir.standardizedFileURL.path)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: dir.path).sorted(), ["call.md", "rec.m4a"])
        XCTAssertTrue(try String(contentsOf: dir.appendingPathComponent("call.md"), encoding: .utf8).hasSuffix("more\n"))
    }

    func testExportRefusesAMissingHandoffRootAndNeverCreatesIt() {
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/handoff")
        let r = SalesCallExport.export(noteText: "## Firm\nX\n", audio: nil, date: Date(), to: missing)
        guard case .skipped = r else { return XCTFail("\(r)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    func testExportConfigDefaultsOffAndDecodesFromOldConfig() throws {
        let cfg = try JSONDecoder().decode(Config.self, from: Data("{}".utf8))
        XCTAssertEqual(cfg.salesExport.folder, "")
        XCTAssertFalse(cfg.salesExport.enabled)
        XCTAssertFalse(Config.recommendedForThisMac().salesExport.enabled)
    }
}
