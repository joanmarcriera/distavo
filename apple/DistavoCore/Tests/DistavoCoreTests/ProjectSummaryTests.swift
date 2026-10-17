import XCTest
@testable import DistavoCore

final class ProjectSummaryTests: XCTestCase {
    let a = ProjectSource(name: "Alpha 2026-01-05", body: "---\ntitle: x\n---\nWe agreed budget of 40 units and a launch on 12 March.")
    let b = ProjectSource(name: "Beta 2026-01-12", body: "Risk: supplier delay of 3 weeks.")

    func testSelectionLimits() {
        XCTAssertNotNil(ProjectSummary.selectionProblem([a]))
        XCTAssertNil(ProjectSummary.selectionProblem([a, b]))
        XCTAssertNotNil(ProjectSummary.selectionProblem([a, a]))
        let many = (0..<11).map { ProjectSource(name: "n\($0)", body: "x") }
        XCTAssertNotNil(ProjectSummary.selectionProblem(many))
    }

    func testDistilledStripsFrontmatter() {
        XCTAssertEqual(ProjectSummary.distilled(a.body), "We agreed budget of 40 units and a launch on 12 March.")
    }

    func testBatchesSplitWhenTheyDoNotFit() {
        let big = (0..<4).map { ProjectSource(name: "n\($0)", body: String(repeating: "word ", count: 1500)) }
        let batches = ProjectSummary.batches(big, contextSize: 4096)
        XCTAssertGreaterThan(batches.count, 1)
        XCTAssertEqual(batches.flatMap { $0 }.map(\.name), big.map(\.name))   // none dropped, order kept
        XCTAssertEqual(ProjectSummary.batches([a, b], contextSize: 8192).count, 1)
    }

    func testOversizedNoteIsShortenedAndMarked() {
        let huge = ProjectSource(name: "h", body: (0..<5000).map { "line \($0)" }.joined(separator: "\n"))
        let out = ProjectSummary.batches([huge], contextSize: 4096)
        XCTAssertTrue(out[0][0].body.hasSuffix("[note shortened to fit the model window]"))
    }

    func testVerifyDropsUnsupportedBullets() {
        let text = """
        ## Progress
        - Budget agreed at 40 units [[Alpha 2026-01-05]]
        - Budget agreed at 99 units [[Alpha 2026-01-05]]
        - Uncited claim
        - Cites a stranger [[Gamma]]
        - Supplier delay of 3 weeks [[beta 2026-01-12]] and launch 12 [[Alpha 2026-01-05]]
        Plain prose stays.
        """
        let r = ProjectSummary.verify(text, sources: [a, b])
        XCTAssertEqual(r.dropped, 3)
        XCTAssertTrue(r.text.contains("40 units"))
        XCTAssertFalse(r.text.contains("99"))
        XCTAssertTrue(r.text.contains("Plain prose stays."))
        XCTAssertTrue(r.text.contains("## Progress"))
    }

    func testSummariseSingleBatchMakesOneCall() async throws {
        var prompts: [String] = []
        let r = try await ProjectSummary.summarise([a, b], title: "P", contextSize: 8192) { p, _ in
            prompts.append(p); return "- Delay of 3 weeks [[Beta 2026-01-12]]"
        }
        XCTAssertEqual(r.calls, 1)
        XCTAssertTrue(prompts[0].contains("=== [[Alpha 2026-01-05]] ==="))
        XCTAssertFalse(prompts[0].contains("title: x"))        // frontmatter not sent
    }

    func testSummariseMapReduce() async throws {
        let big = (0..<4).map { ProjectSource(name: "n\($0)", body: String(repeating: "word ", count: 1500)) }
        var n = 0
        let r = try await ProjectSummary.summarise(big, title: "P", contextSize: 4096) { _, _ in
            n += 1; return "- ok [[n0]]"
        }
        XCTAssertEqual(r.calls, n)
        XCTAssertGreaterThan(r.calls, 2)                         // several maps + one merge
    }

    func testFileNameAndCompose() {
        XCTAssertEqual(ProjectSummary.fileName(title: "Q1/Launch: plan?"), "Project - Q1 Launch plan.md")
        XCTAssertEqual(ProjectSummary.fileName(title: " . "), "Project - Untitled.md")
        let md = ProjectSummary.compose(title: "Launch", sources: [a, b], summary: "- x [[Alpha 2026-01-05]]", droppedLines: 2, date: "2026-10-17")
        XCTAssertTrue(md.hasPrefix("---\ntype: project-summary"))
        XCTAssertTrue(md.contains("  - \"[[Beta 2026-01-12]]\""))
        XCTAssertTrue(md.contains("2 lines removed"))
    }
}

final class ProjectSummaryRunTests: XCTestCase {
    private var notes: URL!
    override func setUpWithError() throws {
        notes = FileManager.default.temporaryDirectory.appendingPathComponent("ps-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        try "Budget of 40 units agreed.".write(to: notes.appendingPathComponent("A.md"), atomically: true, encoding: .utf8)
        try "Delay of 3 weeks.".write(to: notes.appendingPathComponent("B.md"), atomically: true, encoding: .utf8)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: notes) }

    private func config(url: String = "http://localhost:11434") -> Config {
        var c = Config(); c.notesDir = notes.path
        c.summarise.backend = "local"; c.summarise.local = OllamaTarget(url: url, model: "m"); return c
    }
    private func deps(reply: String) -> AskDeps {
        AskDeps(ollamaReachable: { _ in true }, complete: { _, _, _, _, _ in reply }, resolver: { _ in [] })
    }

    func testWritesOneNewNoteAndNeverTouchesSources() async throws {
        let out = await ProjectSummary.run(bases: ["A", "B"], title: "Launch", config: config(),
                                           deps: deps(reply: "## Progress\n- 40 units [[A]]\n- 99 units [[A]]"))
        guard case .written(let url, let dropped, _) = out else { return XCTFail("\(out)") }
        XCTAssertEqual(url.lastPathComponent, "Project - Launch.md")
        XCTAssertEqual(dropped, 1)
        let text = try String(contentsOf: url)
        XCTAssertTrue(text.contains("40 units [[A]]")); XCTAssertFalse(text.contains("99 units"))
        XCTAssertEqual(try String(contentsOf: notes.appendingPathComponent("A.md")), "Budget of 40 units agreed.")
        // a second run does not overwrite
        let again = await ProjectSummary.run(bases: ["A", "B"], title: "Launch", config: config(),
                                             deps: deps(reply: "- 3 weeks [[B]]"))
        guard case .written(let url2, _, _) = again else { return XCTFail("\(again)") }
        XCTAssertEqual(url2.lastPathComponent, "Project - Launch 2.md")
    }

    func testNothingSupportedWritesNothing() async {
        let out = await ProjectSummary.run(bases: ["A", "B"], title: "L", config: config(), deps: deps(reply: "- invented"))
        guard case .failed = out else { return XCTFail("\(out)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: notes.appendingPathComponent("Project - L.md").path))
    }

    func testPublicEndpointIsRefusedBeforeAnyCall() async {
        var called = false
        let d = AskDeps(ollamaReachable: { _ in true }, complete: { _, _, _, _, _ in called = true; return "" },
                        resolver: { _ in ["8.8.8.8"] })
        let out = await ProjectSummary.run(bases: ["A", "B"], title: "L", config: config(url: "http://example.com:11434"), deps: d)
        guard case .refused = out else { return XCTFail("\(out)") }
        XCTAssertFalse(called)
    }

    func testBadSelectionAndMissingNote() async {
        var out = await ProjectSummary.run(bases: ["A"], title: "L", config: config(), deps: deps(reply: ""))
        guard case .failed = out else { return XCTFail() }
        out = await ProjectSummary.run(bases: ["A", "Nope"], title: "L", config: config(), deps: deps(reply: ""))
        guard case .failed(let m) = out else { return XCTFail() }
        XCTAssertTrue(m.contains("Nope"))
    }
}
