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
