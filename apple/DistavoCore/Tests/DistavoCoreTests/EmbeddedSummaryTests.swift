import XCTest
@testable import DistavoCore

/// Tests for the dependency-free half of on-device summarisation (Vikunja #336):
/// token estimation, budgeting, chunk planning and the map/reduce prompts.
/// These run without Apple Intelligence, a model, or macOS 26 — that is the
/// point of keeping this logic in DistavoCore.
final class EmbeddedSummaryTests: XCTestCase {

    /// The real on-device context window, measured on an Apple Silicon Mac
    /// running macOS 26.6 (`SystemLanguageModel.default.contextSize`).
    private let contextSize = 4096

    // MARK: Token estimation

    func testEstimateRoundsUp() {
        XCTAssertEqual(EmbeddedSummaryTokens.estimate(""), 0)
        XCTAssertEqual(EmbeddedSummaryTokens.estimate("a"), 1)       // 1/4 -> 1
        XCTAssertEqual(EmbeddedSummaryTokens.estimate(String(repeating: "a", count: 4)), 1)
        XCTAssertEqual(EmbeddedSummaryTokens.estimate(String(repeating: "a", count: 5)), 2)
    }

    /// The heuristic must not UNDER-count relative to Apple's real tokenizer
    /// (4.10 chars/token measured on Distavo's own prompt) — under-counting
    /// overflows the context window at generation time.
    func testEstimateIsConservativeVersusMeasuredDensity() {
        let text = String(repeating: "word ", count: 1000)   // 5000 chars
        let measuredTokens = Int(Double(text.count) / 4.10)  // what Apple would report
        XCTAssertGreaterThanOrEqual(EmbeddedSummaryTokens.estimate(text), measuredTokens)
    }

    // MARK: Budgets

    func testBudgetSubtractsInstructionsAndOutput() {
        let b = EmbeddedSummaryBudget(
            contextSize: 4096, reservedForOutput: 1800, instructionTokens: 800)
        XCTAssertEqual(b.transcriptTokens, 1496)
    }

    func testBudgetNeverNegative() {
        let b = EmbeddedSummaryBudget(
            contextSize: 1000, reservedForOutput: 800, instructionTokens: 500)
        XCTAssertEqual(b.transcriptTokens, 0)
    }

    /// Distavo's full prompt (779 tokens measured) plus 1800 reserved for the
    /// answer must still leave usable room inside a 4096 window — if this ever
    /// goes to zero, single-pass summarisation is impossible and the planner
    /// would loop producing empty chunks.
    func testFinalBudgetLeavesUsableRoomInRealContextWindow() {
        let b = EmbeddedSummaryBudget.final(
            contextSize: contextSize, noteOwner: "Me", userSpeaker: "unknown")
        XCTAssertGreaterThan(b.transcriptTokens, 500)
        XCTAssertLessThan(b.transcriptTokens, 2600)
    }

    /// The map step's terser instructions must leave more transcript room than
    /// the full-note prompt — otherwise map-reduce could never make progress.
    func testMapBudgetIsLargerThanFinalBudget() {
        let map = EmbeddedSummaryBudget.map(contextSize: contextSize)
        let final = EmbeddedSummaryBudget.final(
            contextSize: contextSize, noteOwner: "Me", userSpeaker: "unknown")
        XCTAssertGreaterThan(map.transcriptTokens, final.transcriptTokens)
    }

    // MARK: Planning

    func testShortTranscriptPlansSinglePass() {
        let plan = EmbeddedSummaryPlanner.plan(
            transcript: "SPEAKER_00: Hello.\nSPEAKER_01: Hi.",
            contextSize: contextSize, noteOwner: "Me", userSpeaker: "unknown")
        XCTAssertEqual(plan, .single)
    }

    func testLongTranscriptPlansMapReduce() {
        // ~40 000 chars ≈ 10 000 tokens — a roughly one-hour meeting.
        let transcript = (0..<800)
            .map { "SPEAKER_0\($0 % 2): This is a sentence of meeting dialogue." }
            .joined(separator: "\n")
        let plan = EmbeddedSummaryPlanner.plan(
            transcript: transcript, contextSize: contextSize,
            noteOwner: "Me", userSpeaker: "unknown")
        guard case let .mapReduce(chunks) = plan else {
            return XCTFail("expected mapReduce, got \(plan)")
        }
        XCTAssertGreaterThan(chunks.count, 1)
    }

    // MARK: Chunking

    func testEveryChunkFitsTheBudget() {
        let transcript = (0..<500)
            .map { "SPEAKER_0\($0 % 2): Some dialogue line number \($0) with content." }
            .joined(separator: "\n")
        let budget = 300
        let chunks = EmbeddedSummaryPlanner.chunks(transcript: transcript, budgetTokens: budget)
        XCTAssertFalse(chunks.isEmpty)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(EmbeddedSummaryTokens.estimate(chunk), budget)
        }
    }

    /// Speaker turns must stay intact — splitting mid-turn would detach words
    /// from their speaker label and corrupt attribution in the notes.
    func testChunksSplitOnlyOnLineBoundaries() {
        let lines = (0..<200).map { "SPEAKER_00: line \($0)" }
        let chunks = EmbeddedSummaryPlanner.chunks(
            transcript: lines.joined(separator: "\n"), budgetTokens: 50)
        let rebuilt = chunks.flatMap { $0.split(separator: "\n").map(String.init) }
        XCTAssertEqual(rebuilt, lines)
    }

    /// No dialogue may be silently dropped: the chunks together must contain
    /// exactly the original content, ignoring whitespace.
    func testChunkingLosesNoContent() {
        let transcript = (0..<300)
            .map { "SPEAKER_0\($0 % 2): Sentence \($0) about the budget and timeline." }
            .joined(separator: "\n")
        let chunks = EmbeddedSummaryPlanner.chunks(transcript: transcript, budgetTokens: 200)
        let strip: (String) -> String = { $0.filter { !$0.isWhitespace } }
        XCTAssertEqual(strip(chunks.joined()), strip(transcript))
    }

    /// A single uninterrupted monologue longer than the budget must still be
    /// broken up rather than emitted as one over-budget chunk.
    func testOverlongSingleLineIsHardSplit() {
        let monologue = "SPEAKER_00: " + String(repeating: "word ", count: 2000)
        let budget = 100
        let chunks = EmbeddedSummaryPlanner.chunks(transcript: monologue, budgetTokens: budget)
        XCTAssertGreaterThan(chunks.count, 1)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(EmbeddedSummaryTokens.estimate(chunk), budget)
        }
    }

    /// Pathological input with no whitespace at all must still terminate and
    /// stay within budget.
    func testUnbrokenTextIsSplitByCharacters() {
        let blob = String(repeating: "x", count: 5000)
        let budget = 50
        let chunks = EmbeddedSummaryPlanner.chunks(transcript: blob, budgetTokens: budget)
        XCTAssertGreaterThan(chunks.count, 1)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(EmbeddedSummaryTokens.estimate(chunk), budget)
        }
        XCTAssertEqual(chunks.joined().count, blob.count)
    }

    func testZeroBudgetProducesNoChunks() {
        XCTAssertTrue(EmbeddedSummaryPlanner.chunks(transcript: "SPEAKER_00: hi", budgetTokens: 0).isEmpty)
    }

    func testEmptyTranscriptProducesNoChunks() {
        XCTAssertTrue(EmbeddedSummaryPlanner.chunks(transcript: "", budgetTokens: 500).isEmpty)
        XCTAssertTrue(EmbeddedSummaryPlanner.chunks(transcript: "\n\n  \n", budgetTokens: 500).isEmpty)
    }

    // MARK: Prompts

    func testMapPromptSubstitutesPlaceholders() {
        let p = EmbeddedSummaryPrompt.map(chunk: "SPEAKER_00: Hello.", index: 2, total: 5)
        XCTAssertTrue(p.contains("Part 2 of 5"))
        XCTAssertTrue(p.contains("SPEAKER_00: Hello."))
        XCTAssertFalse(p.contains("{chunk}"))
        XCTAssertFalse(p.contains("{index}"))
        XCTAssertFalse(p.contains("{total}"))
    }

    func testMergeLabelsEachPartial() {
        let merged = EmbeddedSummaryPrompt.merge(partials: ["alpha", "beta"])
        XCTAssertTrue(merged.contains("Notes from part 1 of 2"))
        XCTAssertTrue(merged.contains("Notes from part 2 of 2"))
        XCTAssertTrue(merged.contains("alpha"))
        XCTAssertTrue(merged.contains("beta"))
    }

    /// The reduce step reuses Distavo's normal prompt, so the final note keeps
    /// the exact section layout SummaryValidator and the app expect.
    func testReduceUsesTheStandardNotePrompt() {
        let merged = EmbeddedSummaryPrompt.merge(partials: ["Key points: budget agreed"])
        let prompt = Prompt.build(transcript: merged, noteOwner: "Marc", userSpeaker: "SPEAKER_00")
        XCTAssertTrue(prompt.contains("# Meeting notes"))
        XCTAssertTrue(prompt.contains("## Action items"))
        XCTAssertTrue(prompt.contains("budget agreed"))
        XCTAssertTrue(prompt.contains("Marc"))
    }
}
