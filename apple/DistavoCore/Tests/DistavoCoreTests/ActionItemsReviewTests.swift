import XCTest
@testable import DistavoCore

/// Review round for #2941: concurrency, in-place writes, prompt fidelity, parser edge cases,
/// Reminders gating.
final class ActionItemsReviewTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("actions-r-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    @discardableResult
    private func write(_ name: String, _ data: Data, age: TimeInterval = 0) throws -> URL {
        let u = dir.appendingPathComponent(name)
        try data.write(to: u)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: u.path)
        return u
    }
    private func write(_ name: String, _ s: String, age: TimeInterval = 0) throws -> URL {
        try write(name, Data(s.utf8), age: age)
    }

    // MARK: 1 & 2 - writes

    func testManyConcurrentTicksAllLand() throws {
        let md = (0..<60).map { "- [ ] task \($0)\n" }.joined()
        let u = try write("c.md", md)
        let items = ActionItems.parse(md, notePath: u.path)
        DispatchQueue.concurrentPerform(iterations: items.count) { i in
            try? ActionItems.toggle(item: items[i], to: true)
        }
        XCTAssertEqual(ActionItems.parse(try String(contentsOf: u, encoding: .utf8)).filter(\.isDone).count, 60)
    }

    func testSymlinkedNoteStaysASymlinkAndXattrsSurvive() throws {
        let real = try write("real.md", "- [ ] a\n")
        let link = dir.appendingPathComponent("link.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let tag = Data("blue".utf8)
        XCTAssertEqual(real.withUnsafeFileSystemRepresentation { p in
            tag.withUnsafeBytes { setxattr(p, "com.apple.metadata:test", $0.baseAddress, tag.count, 0, 0) } }, 0)
        let item = ActionItems.parse("- [ ] a\n", notePath: link.path)[0]
        try ActionItems.toggle(item: item, to: true)
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: link.path))
        XCTAssertEqual(try String(contentsOf: real, encoding: .utf8), "- [x] a\n")
        let size = real.withUnsafeFileSystemRepresentation { getxattr($0, "com.apple.metadata:test", nil, 0, 0, 0) }
        XCTAssertEqual(size, tag.count)
    }

    func testNonUTF8NoteIsRefused() throws {
        var bytes = Array("- [ ] a\n".utf8); bytes.append(contentsOf: [0xFF, 0xFE, 0x0A])
        let u = try write("bad.md", Data(bytes))
        let item = ActionItems.parse("- [ ] a\n", notePath: u.path)[0]
        XCTAssertThrowsError(try ActionItems.toggle(item: item, to: true)) {
            guard case .unreadable(let m) = $0 as? ActionItemsError else { return XCTFail() }
            XCTAssertTrue(m.contains("UTF-8"))
        }
        XCTAssertEqual(try Data(contentsOf: u), Data(bytes))
    }

    // MARK: 3 & 4 - prompt fidelity

    func testStockMarkersStillParseOrCIFailsLoudly() throws {
        for style in [Prompt.Style.classic, .factsFirst] {
            let t = try XCTUnwrap(ActionItemsPrompt.stockTemplate(for: style),
                                  "the stock prompt layout changed: update ActionItemsPrompt.stockTemplate")
            XCTAssertTrue(t.headings.contains("## Decisions made"))
            XCTAssertTrue(t.headings.contains("## Action items"))
        }
    }

    private func prompt(_ style: Prompt.Style, on: Bool) -> String {
        Prompt.build(transcript: "T", noteOwner: "Marc", userSpeaker: "SPEAKER_00", style: style,
                     meetingDate: Date(timeIntervalSince1970: 1_790_000_000),
                     template: ActionItemsPrompt.effectiveTemplate(nil, style: style, enabled: on))
    }

    private func dropLines(_ s: String, prefixes: [String]) -> String {
        s.components(separatedBy: "\n").filter { l in !prefixes.contains { l.hasPrefix($0) } }.joined(separator: "\n")
    }

    func testOnAndOffPromptsDifferOnlyInTheSwappedSectionsAndTwoClassicRules() {
        for style in [Prompt.Style.classic, .factsFirst] {
            var off = prompt(style, on: false), on = prompt(style, on: true)
            if style == .classic {
                off = dropLines(off, prefixes: ["- For action items, distinguish:", "  1. Explicit", "  2. Implied",
                                                "  3. Possible", "- Give each action's own deadline"])
                on = dropLines(on, prefixes: ["- For tasks, say in the task text", "- Give each task a due date"])
            }
            let offHead = off.components(separatedBy: "## Decisions made")
            let onHead = on.components(separatedBy: "## Decisions\n")
            XCTAssertEqual(offHead.count, 2, "\(style)"); XCTAssertEqual(onHead.count, 2, "\(style)")
            XCTAssertEqual(offHead[0], onHead[0], "\(style): text before the swapped sections must be verbatim")
            let offTail = off.components(separatedBy: "## Highest-ROI follow-up")
            let onTail = on.components(separatedBy: "## Highest-ROI follow-up")
            XCTAssertEqual(offTail[1...].joined(separator: "|"), onTail[1...].joined(separator: "|"),
                           "\(style): text after the swapped sections must be verbatim")
        }
    }

    func testFactsFirstLedgerRuleSurvivesWhenOn() {
        let on = prompt(.factsFirst, on: true)
        XCTAssertTrue(on.contains("if the ledger has a rate, the commercial section states it"))
    }

    func testClassicContradictoryRulesAreReworded() {
        let on = prompt(.classic, on: true)
        XCTAssertFalse(on.contains("Post-engagement / not yet active\" for the rare"))
        XCTAssertFalse(on.contains("For action items, distinguish:"))
        XCTAssertTrue(on.contains("due: none"))
        // A user template with Tasks gets the same consistency.
        let t = ActionItemsPrompt.effectiveTemplate(
            SummaryTemplateCatalog.bundledTemplates[0], style: .classic, enabled: true)
        XCTAssertFalse(Prompt.build(transcript: "T", noteOwner: "M", userSpeaker: "S", template: t)
            .contains("distinguish:"))
    }

    // MARK: 6 - Reminders

    final class SlowSink: ReminderSink {
        var created = 0
        func requestAccess() async -> ReminderAccess { try? await Task.sleep(nanoseconds: 100_000_000); return .granted }
        func create(_ r: NewReminder) throws { created += 1 }
    }

    func testConcurrentExportsCannotDuplicate() async {
        let items = ActionItems.parse("- [ ] a\n- [ ] b\n", notePath: "/n/x.md")
        let sink = SlowSink(), d = dir!
        async let r1 = RemindersExport.export(items: items, noteTitle: "T", sink: sink, workDir: d)
        async let r2 = RemindersExport.export(items: items, noteTitle: "T", sink: sink, workDir: d)
        let results = await [r1, r2]
        XCTAssertTrue(results.contains(.busy))
        XCTAssertEqual(sink.created, 2)
        XCTAssertEqual(RemindersLedger.load(workDir: d).sent.count, 2)
    }

    func testCorruptLedgerIsMovedAsideNotReset() throws {
        try write(RemindersLedger.fileName, "{not json")
        XCTAssertTrue(RemindersLedger.load(workDir: dir).sent.isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(names.contains { $0.hasPrefix(RemindersLedger.fileName + ".corrupt-") })
        XCTAssertFalse(names.contains(RemindersLedger.fileName))
    }

    // MARK: 7 - parser and scan

    func testParserEdgeCases() {
        // ~~~ inside a ``` fence does not close it.
        XCTAssertEqual(ActionItems.parse("```\n~~~\n- [ ] in code\n```\n- [ ] real\n").map(\.title), ["real"])
        // 4-space indented code is not a task; a nested item under a list is.
        XCTAssertEqual(ActionItems.parse("Text\n\n    - [ ] code\n\n- [ ] top\n    - [ ] nested\n").map(\.title),
                       ["top", "nested"])
        XCTAssertEqual(ActionItems.parse("Text\n\n\t- [ ] tab code\n").count, 0)
        // Ordered list checkboxes.
        XCTAssertEqual(ActionItems.parse("1. [ ] one\n2) [x] two\n").map(\.isDone), [false, true])
        // BOM on line 1.
        let bom = "\u{FEFF}- [ ] first\n- [ ] second\n"
        XCTAssertEqual(ActionItems.parse(bom).map(\.title), ["first", "second"])
    }

    func testTickingWorksOnBOMFile() throws {
        let content = "\u{FEFF}- [ ] first\n"
        let u = try write("bom.md", content)
        try ActionItems.toggle(item: ActionItems.parse(content, notePath: u.path)[0], to: true)
        XCTAssertEqual(try Data(contentsOf: u), Data("\u{FEFF}- [x] first\n".utf8))
    }

    func testScanExaminesOnlyTheNewest500Notes() throws {
        try write("oldest.md", "- [ ] ancient\n", age: 100_000)
        for i in 0..<ActionItems.maxNotesExamined { try write("n\(i).md", "nothing\n", age: Double(i)) }
        XCTAssertTrue(ActionItems.scan(notesDir: dir).isEmpty)
    }
}
