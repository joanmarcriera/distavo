import XCTest
@testable import DistavoCore

/// Vikunja #2954: the title/tags request and its lenient, sanitising parser.
final class NoteMetaTests: XCTestCase {

    func testNothingRequestedLeavesInstructionAndPromptUntouched() {
        let off = NotesConfig()
        XCTAssertEqual(NoteMeta.requestText(off), "")
        XCTAssertNil(NoteMeta.mergedInstruction(nil, notes: off))
        XCTAssertEqual(NoteMeta.mergedInstruction("keep it short", notes: off), "keep it short")
        // Only frontmatter / tracked terms / a vault do not touch the prompt either.
        let other = NotesConfig(frontmatter: true, trackedTerms: ["x"], vaultDir: "/v")
        XCTAssertNil(NoteMeta.mergedInstruction(nil, notes: other))
        // ...so Prompt.build is byte-identical.
        let a = NoteContext(noteOwner: "Me", userSpeaker: "S", customInstruction: NoteMeta.mergedInstruction(nil, notes: other))
        let b = NoteContext(noteOwner: "Me", userSpeaker: "S")
        XCTAssertEqual(a.prompt(transcript: "t"), b.prompt(transcript: "t"))
    }

    func testRequestNamesOnlyTheEnabledLines() {
        let both = NoteMeta.requestText(NotesConfig(autoTitle: true, autoTags: true))
        XCTAssertTrue(both.contains("Distavo-Title:") && both.contains("Distavo-Tags:"))
        let t = NoteMeta.requestText(NotesConfig(autoTitle: true))
        XCTAssertTrue(t.contains("Distavo-Title:")); XCTAssertFalse(t.contains("Distavo-Tags:"))
        XCTAssertFalse(NoteMeta.requestText(NotesConfig(autoTags: true)).contains("Distavo-Title:"))
    }

    func testRequestReachesThePromptAndFitsTheInstructionCap() {
        let notes = NotesConfig(autoTitle: true, autoTags: true)
        let merged = NoteMeta.mergedInstruction(String(repeating: "x", count: 5000), notes: notes)!
        XCTAssertLessThanOrEqual(merged.count, Prompt.maxCustomInstructionChars)
        XCTAssertTrue(merged.hasSuffix(NoteMeta.requestText(notes)), "the request is kept whole")
        let prompt = NoteContext(noteOwner: "Me", userSpeaker: "S", customInstruction: merged).prompt(transcript: "t")
        XCTAssertTrue(prompt.contains("Distavo-Title:"))
        XCTAssertTrue(NoteMeta.mergedInstruction(nil, notes: notes)!.hasPrefix("After the notes"))
    }

    func testExtractRemovesLinesAndParsesValues() {
        let text = "# Meeting notes\n\n## A\nbody\n\nDistavo-Title: Q4 roadmap review\nDistavo-Tags: Roadmap, hiring, Budget Plan\n"
        let e = NoteMeta.extract(from: text)
        XCTAssertEqual(e.title, "Q4 roadmap review")
        XCTAssertEqual(e.tags, ["roadmap", "hiring", "budget-plan"])
        XCTAssertEqual(e.body, "# Meeting notes\n\n## A\nbody\n")
        XCTAssertFalse(e.body.contains("Distavo-"))
    }

    func testExtractIsLenientAboutDecorationAndCase() {
        let text = "body\n**Distavo-Title:** \"Pricing call\"\n- `distavo-tags`: #pricing, #q4\n"
        let e = NoteMeta.extract(from: text)
        XCTAssertEqual(e.title, "Pricing call")
        XCTAssertEqual(e.tags, ["pricing", "q4"])
        XCTAssertEqual(e.body, "body\n")
    }

    func testNoLinesMeansUnchangedAndNoFailure() {
        let text = "# Meeting notes\n\ntext\n"
        let e = NoteMeta.extract(from: text)
        XCTAssertEqual(e, NoteMeta.Extracted(body: text, title: nil, tags: []))
    }

    func testMalformedValuesYieldNothingButStillStripTheLines() {
        let e = NoteMeta.extract(from: "body\nDistavo-Title:\nDistavo-Tags: , ;; #\n")
        XCTAssertNil(e.title); XCTAssertEqual(e.tags, []); XCTAssertEqual(e.body, "body\n")
        // An echoed placeholder is not a title / tags.
        let echo = NoteMeta.extract(from: "b\nDistavo-Title: <a specific title for this meeting, at most 10 words, no quotes>\nDistavo-Tags: <3 to 6 lowercase topic keywords, comma-separated, no # signs>")
        XCTAssertNil(echo.title); XCTAssertEqual(echo.tags, [])
    }

    func testLastOccurrenceWinsForChunkedSummaries() {
        let e = NoteMeta.extract(from: "a\nDistavo-Title: First\nb\nDistavo-Title: Second\nDistavo-Tags: x\nDistavo-Tags: y, z\n")
        XCTAssertEqual(e.title, "Second"); XCTAssertEqual(e.tags, ["y", "z"])
        XCTAssertEqual(e.body, "a\nb\n")
    }

    func testTitleSanitising() {
        XCTAssertEqual(NoteMeta.sanitisedTitle("Plan A/B: scope\\owners"), "Plan A - B - scope - owners")
        XCTAssertEqual(NoteMeta.sanitisedTitle("  “Quoted  \t title”  "), "Quoted title")
        XCTAssertNil(NoteMeta.sanitisedTitle("   "))
        XCTAssertNil(NoteMeta.sanitisedTitle("/"))
        let long = NoteMeta.sanitisedTitle(String(repeating: "word ", count: 40))!
        XCTAssertLessThanOrEqual(long.count, NoteMeta.maxTitleChars)
        XCTAssertFalse(long.hasSuffix(" "))
        XCTAssertFalse(NoteMeta.sanitisedTitle("a/b")!.contains("/"))
    }

    func testTagSlugsAreObsidianSafeAndCapped() {
        XCTAssertEqual(NoteMeta.slug("#Hello World"), "hello-world")
        XCTAssertEqual(NoteMeta.slug("2026"), "n2026")                 // never digits-only
        XCTAssertEqual(NoteMeta.slug("Q4 2026"), "q4-2026")
        XCTAssertEqual(NoteMeta.slug("a//b"), "a/b")
        XCTAssertEqual(NoteMeta.slug("  --x--  "), "x")
        XCTAssertEqual(NoteMeta.slug("Cañón, ¿qué?"), "cañón-qué")
        XCTAssertNil(NoteMeta.slug("###")); XCTAssertNil(NoteMeta.slug(""))
        XCTAssertFalse(NoteMeta.slug("emoji 🚀 tag")!.contains(" "))
        let many = NoteMeta.sanitisedTags((1...20).map { "t\($0)" }.joined(separator: ","))
        XCTAssertEqual(many.count, NoteMeta.maxTags)
        XCTAssertEqual(NoteMeta.sanitisedTags("A, a, A "), ["a"])
    }
}
