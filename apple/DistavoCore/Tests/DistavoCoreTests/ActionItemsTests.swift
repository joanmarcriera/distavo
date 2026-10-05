import XCTest
@testable import DistavoCore

/// Vikunja #2941: parsing, ticking, scanning, the Tasks prompt/validation, the
/// config key's migration and the Reminders export decision logic.
final class ActionItemsTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("actions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    @discardableResult
    private func write(_ name: String, _ content: String, age: TimeInterval = 0) throws -> URL {
        let u = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: u)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: u.path)
        return u
    }

    // MARK: parsing

    func testParsesOpenAndClosedWithOwnerAndDue() {
        let md = """
        # Weekly sync

        ## Tasks
        - [ ] Send the quote — owner: Ana; due: 2026-10-12
        - [x] Book room — owner: unassigned; due: none
        * [ ] star bullet
          - [X] indented upper-case
        - [ ]no space is not a task
        - [] neither
        """
        let items = ActionItems.parse(md, notePath: "/n/a.md")
        XCTAssertEqual(items.map(\.title), ["Send the quote", "Book room", "star bullet", "indented upper-case"])
        XCTAssertEqual(items.map(\.isDone), [false, true, false, true])
        XCTAssertEqual(items[0].owner, "Ana")
        XCTAssertEqual(items[0].due, "2026-10-12")
        XCTAssertNil(items[1].owner)
        XCTAssertNil(items[1].due)
        XCTAssertEqual(items[0].lineNumber, 4)
        XCTAssertEqual(items[0].sourceLink.fragment, "L4")
        XCTAssertEqual(items[0].sourceLink.path, "/n/a.md")
    }

    func testMalformedDueIsIgnoredAndTitleKept() {
        let i = ActionItems.parse("- [ ] Call Bob due: next week", notePath: "x")[0]
        XCTAssertNil(i.due)
        XCTAssertEqual(i.title, "Call Bob")
    }

    func testCodeFencesAreNotTasks() {
        let md = "```\n- [ ] in code\n```\n- [ ] real\n"
        XCTAssertEqual(ActionItems.parse(md).map(\.title), ["real"])
    }

    func testIdentityIsStableAcrossTickingAndDistinguishesDuplicates() {
        let a = ActionItems.parse("- [ ] same\n- [ ] same\n- [ ] other\n", notePath: "p")
        let b = ActionItems.parse("- [x] same\n- [ ] same\n- [ ] other\n", notePath: "p")
        XCTAssertEqual(a[0].id, b[0].id)
        XCTAssertNotEqual(a[0].id, a[1].id)
        XCTAssertNotEqual(a[0].id, a[2].id)
    }

    // MARK: toggling

    func testTickRewritesExactlyOneByte() throws {
        let original = "# T\n\n- [ ] one\n- [ ] two\n\nend"            // no trailing newline
        let u = try write("a.md", original)
        let items = ActionItems.parse(original, notePath: u.path)
        try ActionItems.toggle(item: items[1], to: true)
        let after = try String(contentsOf: u, encoding: .utf8)
        XCTAssertEqual(after, "# T\n\n- [ ] one\n- [x] two\n\nend")
        try ActionItems.toggle(item: items[1], to: false)
        XCTAssertEqual(try String(contentsOf: u, encoding: .utf8), original)
    }

    func testCRLFAndUnicodeArePreservedByteForByte() throws {
        let original = "# Títol\r\n\r\n- [ ] Enviar l'oferta — owner: Núria\r\n- [ ] altre\r\n"
        let u = try write("crlf.md", original)
        let items = ActionItems.parse(original, notePath: u.path)
        XCTAssertEqual(items.count, 2)
        try ActionItems.toggle(item: items[0], to: true)
        let expected = original.replacingOccurrences(of: "- [ ] Enviar", with: "- [x] Enviar")
        XCTAssertEqual(try Data(contentsOf: u), Data(expected.utf8))
    }

    func testRelocatesByContentWhenLinesMoved() throws {
        let original = "- [ ] alpha\n- [ ] beta\n"
        let u = try write("m.md", original)
        let beta = ActionItems.parse(original, notePath: u.path)[1]            // line 2 at scan time
        try Data("intro\nmore\n- [ ] alpha\n- [ ] beta\n".utf8).write(to: u)     // now line 4
        try ActionItems.toggle(item: beta, to: true)
        XCTAssertEqual(try String(contentsOf: u, encoding: .utf8), "intro\nmore\n- [ ] alpha\n- [x] beta\n")
    }

    func testDuplicateLinesTickTheRightOne() throws {
        let original = "- [ ] dup\n- [ ] dup\n"
        let u = try write("d.md", original)
        let items = ActionItems.parse(original, notePath: u.path)
        try ActionItems.toggle(item: items[1], to: true)
        XCTAssertEqual(try String(contentsOf: u, encoding: .utf8), "- [ ] dup\n- [x] dup\n")
    }

    func testChangedOrDeletedLineFailsAndTouchesNothing() throws {
        let original = "- [ ] alpha\n"
        let u = try write("c.md", original)
        let item = ActionItems.parse(original, notePath: u.path)[0]
        let edited = "- [ ] alpha, edited by hand\n"
        try Data(edited.utf8).write(to: u)
        let before = try FileManager.default.attributesOfItem(atPath: u.path)[.modificationDate] as! Date
        XCTAssertThrowsError(try ActionItems.toggle(item: item, to: true)) {
            XCTAssertEqual($0 as? ActionItemsError, .noteChanged)
        }
        XCTAssertEqual(try String(contentsOf: u, encoding: .utf8), edited)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: u.path)[.modificationDate] as! Date, before)
        try FileManager.default.removeItem(at: u)
        XCTAssertThrowsError(try ActionItems.toggle(item: item, to: true))   // unreadable
    }

    // MARK: scanning

    func testScanListsOpenItemsNewestFirstAndSkipsBackupsAndOthers() throws {
        try write("old.md", "# Old call\n- [ ] old task\n", age: 5000)
        try write("sub/new.md", "# Meeting notes\n- [ ] new task\n- [x] done task\n", age: 10)
        try write("sub/new.prev-20261005-143000.md", "- [ ] backup task\n", age: 1)
        try write("notes.txt", "- [ ] not markdown\n")
        try write("alldone.md", "- [x] finished\n")
        try write(".hidden.md", "- [ ] hidden\n")
        let groups = ActionItems.scan(notesDir: dir)
        XCTAssertEqual(groups.map { $0.path.components(separatedBy: "/").last }, ["new.md", "old.md"])
        XCTAssertEqual(groups[0].items.map(\.title), ["new task"])
        XCTAssertEqual(groups[0].title, "new")                 // "# Meeting notes" is not a title
        XCTAssertEqual(groups[1].title, "Old call")
    }

    func testScanIsBoundedAndSkipsHugeNotes() throws {
        for i in 0..<5 { try write("n\(i).md", "- [ ] t\(i)\n- [ ] u\(i)\n", age: Double(i)) }
        XCTAssertEqual(ActionItems.scan(notesDir: dir, maxNotes: 2).count, 2)
        XCTAssertEqual(ActionItems.scan(notesDir: dir, maxItems: 3).flatMap(\.items).count, 3)
        try write("huge.md", String(repeating: "x", count: ActionItems.maxNoteBytes + 10) + "\n- [ ] huge\n", age: -100)
        XCTAssertFalse(ActionItems.scan(notesDir: dir).contains { $0.path.hasSuffix("huge.md") })
    }

    // MARK: prompt

    private func build(style: Prompt.Style, template: SummaryTemplate?) -> String {
        Prompt.build(transcript: "T", noteOwner: "Marc", userSpeaker: "SPEAKER_00",
                     style: style, template: template)
    }

    func testOffLeavesEveryPromptByteIdentical() {
        for style in [Prompt.Style.classic, .factsFirst] {
            XCTAssertNil(ActionItemsPrompt.effectiveTemplate(nil, style: style, enabled: false))
            for t in SummaryTemplateCatalog.bundledTemplates {
                XCTAssertEqual(ActionItemsPrompt.effectiveTemplate(t, style: style, enabled: false), t)
            }
        }
    }

    func testOnReplacesStockSectionsInBothStyles() {
        for style in [Prompt.Style.classic, .factsFirst] {
            let t = ActionItemsPrompt.effectiveTemplate(nil, style: style, enabled: true)!
            let p = build(style: style, template: t)
            XCTAssertTrue(p.contains("## Tasks"))
            XCTAssertTrue(p.contains(ActionItemsPrompt.taskFormat))
            XCTAssertTrue(p.contains("## Decisions\n"))
            XCTAssertFalse(p.contains("## Action items"))
            XCTAssertFalse(p.contains("## Decisions made"))
            XCTAssertEqual(p.components(separatedBy: "\n## Tasks\n").count, 2)         // exactly once
            // The rest of the stock layout survives.
            XCTAssertTrue(p.contains("## Executive summary"))
            XCTAssertTrue(p.contains("## Suggested follow-up email"))
            XCTAssertTrue(p.hasSuffix("Transcript:\n\nT\n"))
        }
        XCTAssertTrue(build(style: .factsFirst, template: ActionItemsPrompt.effectiveTemplate(nil, style: .factsFirst, enabled: true))
            .contains("## Facts ledger"))
    }

    func testTemplateWithActionItemsGetsTasksInPlaceElseAppended() {
        let standup = SummaryTemplateCatalog.bundledTemplates.first { $0.id == "standup" }!
        let a = ActionItemsPrompt.effectiveTemplate(standup, style: .classic, enabled: true)!
        XCTAssertEqual(a.headings.filter { $0 == "## Tasks" }.count, 1)
        XCTAssertFalse(a.headings.contains("## Action items"))
        XCTAssertEqual(a.headings.firstIndex(of: "## Tasks"), standup.headings.firstIndex(of: "## Action items"))

        let lecture = SummaryTemplateCatalog.bundledTemplates.first { $0.id == "lecture" }!
        let b = ActionItemsPrompt.effectiveTemplate(lecture, style: .classic, enabled: true)!
        XCTAssertEqual(b.headings.last, "## Tasks")
        XCTAssertEqual(b.headings.count, lecture.headings.count + 1)
    }

    func testRequiredHeadingsKnowTheNewSectionsForHeadingRepair() {
        for style in [Prompt.Style.classic, .factsFirst] {
            let t = ActionItemsPrompt.effectiveTemplate(nil, style: style, enabled: true)
            let req = SummaryPostProcess.requiredHeadings(for: style, template: t)
            XCTAssertTrue(req.contains("## Tasks")); XCTAssertTrue(req.contains("## Decisions"))
            XCTAssertFalse(req.contains("## Action items"))
            let repaired = SummaryPostProcess.ensureHeadings("# Meeting notes\n\n## Executive summary\nx\n", style: style, template: t)
            XCTAssertTrue(repaired.contains("## Tasks\n\nnone stated"))
        }
    }

    // MARK: lenient validation

    func testTasksReportIsLenient() {
        let good = "# Meeting notes\n\n## Tasks\n- [ ] a — owner: x; due: none\n- [x] b\n\n## Next\n- not a task\n"
        XCTAssertEqual(SummaryValidator.tasksReport(good), TasksReport(hasSection: true, wellFormed: 2, malformed: []))
        let bad = "## Tasks\n- plain bullet\n| a | b |\nnone stated\n"
        let r = SummaryValidator.tasksReport(bad)
        XCTAssertEqual(r.malformed, ["- plain bullet", "| a | b |"])
        XCTAssertFalse(r.isClean)
        XCTAssertTrue(SummaryValidator.tasksReport("## Other\n- x\n").isClean)
        // The generic validator never fails over the Tasks format.
        let long = "# Meeting notes\n\n## Tasks\n- plain bullet\n\n" + String(repeating: "word", count: 1) + " "
            + (0..<60).map { "w\($0)" }.joined(separator: " ")
        XCTAssertTrue(SummaryValidator.validate(long).isEmpty)
    }

    // MARK: config

    func testConfigPredatingTheKeyDecodesToOff() throws {
        for json in ["{}", #"{"summarise": {"backend": "local"}}"#, #"{"summarise": {"action_items": "yes"}}"#] {
            let cfg = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
            XCTAssertFalse(cfg.summarise.actionItems)
        }
        XCTAssertFalse(Config.recommendedForThisMac().summarise.actionItems)
        var c = Config(); c.summarise.actionItems = true
        let data = try JSONEncoder().encode(c)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"action_items\""))
        XCTAssertTrue(try JSONDecoder().decode(Config.self, from: data).summarise.actionItems)
    }

    // MARK: Reminders

    final class FakeSink: ReminderSink {
        var access: ReminderAccess = .granted
        var asked = 0
        var created: [NewReminder] = []
        var failAt: Int?
        func requestAccess() async -> ReminderAccess { asked += 1; return access }
        func create(_ r: NewReminder) throws {
            if failAt == created.count { throw ActionItemsError.noteChanged }
            created.append(r)
        }
    }

    func testReminderCarriesTextDueNotesAndLink() {
        let i = ActionItems.parse("- [ ] Send quote — owner: Ana; due: 2026-10-12", notePath: "/n/a.md")[0]
        let r = RemindersExport.reminder(for: i, noteTitle: "Acme call")
        XCTAssertEqual(r.title, "Send quote")
        XCTAssertEqual(r.due, DateComponents(year: 2026, month: 10, day: 12))
        XCTAssertTrue(r.notes.contains("Acme call"))
        XCTAssertTrue(r.notes.contains("file:///n/a.md#L1"))
        XCTAssertNil(RemindersExport.reminder(for: ActionItems.parse("- [ ] x", notePath: "p")[0], noteTitle: "").due)
    }

    func testExportDedupesAcrossRunsAndSkipsTickedItems() async throws {
        let items = ActionItems.parse("- [ ] a\n- [ ] b\n- [x] c\n", notePath: "/n/x.md")
        let sink = FakeSink()
        let first = await RemindersExport.export(items: items, noteTitle: "T", sink: sink, workDir: dir)
        XCTAssertEqual(first, .exported(created: 2, alreadySent: 0))
        XCTAssertEqual(sink.created.map(\.title), ["a", "b"])
        let second = await RemindersExport.export(items: items, noteTitle: "T", sink: sink, workDir: dir)
        XCTAssertEqual(second, .exported(created: 0, alreadySent: 2))
        XCTAssertEqual(sink.created.count, 2)
        XCTAssertEqual(sink.asked, 1, "nothing new to send must not ask for access again")
    }

    func testDeniedAccessCreatesNothingAndRecordsNothing() async {
        let sink = FakeSink(); sink.access = .denied
        let items = ActionItems.parse("- [ ] a\n", notePath: "/n/x.md")
        let r = await RemindersExport.export(items: items, noteTitle: "T", sink: sink, workDir: dir)
        XCTAssertEqual(r, .accessDenied)
        XCTAssertTrue(sink.created.isEmpty)
        XCTAssertTrue(RemindersLedger.load(workDir: dir).sent.isEmpty)
        sink.access = .granted                       // permission granted later: the item is still sendable
        let r2 = await RemindersExport.export(items: items, noteTitle: "T", sink: sink, workDir: dir)
        XCTAssertEqual(r2, .exported(created: 1, alreadySent: 0))
    }

    func testPartialFailureKeepsLedgerOfWhatWasCreated() async {
        let items = ActionItems.parse("- [ ] a\n- [ ] b\n", notePath: "/n/x.md")
        let sink = FakeSink(); sink.failAt = 1
        let r = await RemindersExport.export(items: items, noteTitle: "T", sink: sink, workDir: dir)
        if case .failed = r {} else { XCTFail("expected failure, got \(r)") }
        XCTAssertEqual(RemindersLedger.load(workDir: dir).sent, [items[0].id])
    }

    // MARK: fixture meeting

    func testFixtureMeetingYieldsTasksSectionEndToEnd() throws {
        // A model answer in the requested format, as the pipeline would write it.
        let note = """
        # Meeting notes

        ## Executive summary
        Pricing call.

        ## Decisions
        - Go with the annual plan.

        ## Tasks
        - [ ] Send the revised quote — owner: Marc; due: 2026-10-09
        - [ ] Confirm the start date — owner: unassigned; due: none
        """
        XCTAssertTrue(SummaryValidator.tasksReport(note).isClean)
        let u = try write("fixture.md", note)
        let open = ActionItems.scan(notesDir: dir).flatMap(\.items)
        XCTAssertEqual(open.count, 2)
        try ActionItems.toggle(item: open[0], to: true)
        XCTAssertTrue(try String(contentsOf: u, encoding: .utf8).contains("- [x] Send the revised quote"))
        XCTAssertEqual(ActionItems.scan(notesDir: dir).flatMap(\.items).count, 1)
    }
}
