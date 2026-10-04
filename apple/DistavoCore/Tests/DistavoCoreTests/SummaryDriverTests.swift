import XCTest
@testable import DistavoCore

/// Tests for the engine-agnostic driver (Vikunja #2198 S3). Everything here
/// runs against a fake `SummaryGenerator`, so the plan/map/reduceToFit/final
/// flow — previously behind `#if canImport(FoundationModels)` — is covered
/// without Apple Intelligence or a model.
final class SummaryDriverTests: XCTestCase {

    /// Records every call; answers via `respond`.
    final class FakeGenerator: SummaryGenerator, @unchecked Sendable {
        let contextSize: Int
        private let measure: (@Sendable (String) -> Int?)?
        private let respond: @Sendable (String, Int) throws -> String
        private let lock = NSLock()
        private var _prompts: [String] = []
        private var _maxTokens: [Int] = []

        init(contextSize: Int,
             tokenCount: (@Sendable (String) -> Int?)? = nil,
             respond: @escaping @Sendable (String, Int) throws -> String = { prompt, _ in
                 prompt.hasPrefix("You are reading ONE PART") ? "Key points:\n- a point" : "# Meeting notes\n\n## Executive summary\nok"
             }) {
            self.contextSize = contextSize; self.measure = tokenCount; self.respond = respond
        }
        func tokenCount(_ text: String) async -> Int? { measure?(text) }
        func generate(_ prompt: String, maxOutputTokens: Int) async throws -> String {
            lock.lock(); _prompts.append(prompt); _maxTokens.append(maxOutputTokens); lock.unlock()
            return try respond(prompt, maxOutputTokens)
        }
        var prompts: [String] { lock.lock(); defer { lock.unlock() }; return _prompts }
        var maxTokens: [Int] { lock.lock(); defer { lock.unlock() }; return _maxTokens }
    }

    /// A transcript-shaped body of roughly `chars` characters.
    private func transcript(chars: Int) -> String {
        var lines: [String] = []
        var n = 0
        while lines.joined(separator: "\n").count < chars {
            lines.append("SPEAKER_0\(n % 2): Point number \(n) about the migration timeline and the budget.")
            n += 1
        }
        return lines.joined(separator: "\n")
    }

    private func request(_ text: String, style: Prompt.Style = .classic,
                         participants: String? = nil, block: String? = nil) -> SummaryRequest {
        SummaryRequest(transcript: text, noteOwner: "Marc", userSpeaker: "SPEAKER_00",
                       participants: participants, style: style, endOfTurnBlock: block)
    }

    // MARK: Parity with the pre-refactor Foundation Models flow

    /// Single pass: exactly one call, the classic prompt byte-for-byte, the
    /// 1800-token output reserve.
    func testSinglePassPromptIsByteIdenticalToPreRefactor() async throws {
        let text = transcript(chars: 2_000)
        let gen = FakeGenerator(contextSize: 4096)
        _ = try await SummaryDriver.run(request(text, participants: "Marc and Ana"), generator: gen)
        XCTAssertEqual(gen.prompts, [
            Prompt.build(transcript: text, noteOwner: "Marc", userSpeaker: "SPEAKER_00",
                         participants: "Marc and Ana")])
        XCTAssertEqual(gen.maxTokens, [1800])
    }

    /// Map-reduce at Apple's 4096 window: the sequence of prompts and output
    /// limits equals what the old `EmbeddedSummariser.summarise` produced,
    /// re-derived here from the same building blocks it called.
    func testMapReducePromptSequenceIsByteIdenticalToPreRefactor() async throws {
        let text = transcript(chars: 40_000)
        let gen = FakeGenerator(contextSize: 4096)
        _ = try await SummaryDriver.run(request(text, participants: "Marc and Ana"), generator: gen)

        let mapBudget = EmbeddedSummaryBudget.map(contextSize: 4096)
        let chunks = EmbeddedSummaryPlanner.chunks(transcript: text, budgetTokens: mapBudget.transcriptTokens)
        XCTAssertGreaterThan(chunks.count, 1)
        var expected = chunks.enumerated().map {
            EmbeddedSummaryPrompt.map(chunk: $0.element, index: $0.offset + 1, total: chunks.count)
        }
        // The fake answers every map call identically, so the merged notes are:
        let merged = EmbeddedSummaryPrompt.merge(partials: Array(repeating: "Key points:\n- a point", count: chunks.count))
        XCTAssertLessThanOrEqual(EmbeddedSummaryTokens.estimate(merged),
                                 EmbeddedSummaryBudget.final(contextSize: 4096, noteOwner: "Marc", userSpeaker: "SPEAKER_00").transcriptTokens)
        expected.append(Prompt.build(transcript: merged, noteOwner: "Marc", userSpeaker: "SPEAKER_00",
                                     participants: "Marc and Ana"))
        XCTAssertEqual(gen.prompts, expected)
        XCTAssertEqual(gen.maxTokens, Array(repeating: 700, count: chunks.count) + [1800])
    }

    func testProgressMessagesMatchPreRefactorWording() async throws {
        final class Box: @unchecked Sendable { var msgs: [String] = []; let l = NSLock()
            func add(_ m: String) { l.lock(); msgs.append(m); l.unlock() } }
        let box = Box()
        let gen = FakeGenerator(contextSize: 4096)
        _ = try await SummaryDriver.run(request(transcript(chars: 40_000)), generator: gen,
                                        onProgress: { box.add($0) })
        XCTAssertEqual(box.msgs.first, "Summarising part 1 of \(box.msgs.count - 1) on this Mac…")
        XCTAssertEqual(box.msgs.last, "Writing the note…")
    }

    // MARK: Context size drives the plan

    func testLargeContextTakesOneCallWhereSmallOneMapReduces() async throws {
        let text = transcript(chars: 30_000)   // ~10K tokens
        let small = FakeGenerator(contextSize: 4096)
        _ = try await SummaryDriver.run(request(text), generator: small)
        XCTAssertGreaterThan(small.prompts.count, 2)

        let large = FakeGenerator(contextSize: 16384)
        _ = try await SummaryDriver.run(request(text), generator: large)
        XCTAssertEqual(large.prompts.count, 1)
    }

    func testFactsFirstReservesMoreOutputAndUsesItsPrompt() async throws {
        let text = transcript(chars: 6_000)
        let gen = FakeGenerator(contextSize: 16384)
        _ = try await SummaryDriver.run(request(text, style: .factsFirst), generator: gen)
        XCTAssertEqual(gen.maxTokens, [3500])
        XCTAssertEqual(gen.prompts, [
            Prompt.build(transcript: text, noteOwner: "Marc", userSpeaker: "SPEAKER_00", style: .factsFirst)])
    }

    func testEndOfTurnBlockIsAppendedToTheFinalPromptOnly() async throws {
        let text = transcript(chars: 40_000)
        let gen = FakeGenerator(contextSize: 4096)
        _ = try await SummaryDriver.run(request(text, block: "FINAL REMINDER: x"), generator: gen)
        let prompts = gen.prompts
        XCTAssertTrue(prompts.last!.hasSuffix("\nFINAL REMINDER: x\n"))
        XCTAssertFalse(prompts.dropLast().contains { $0.contains("FINAL REMINDER") })
    }

    func testNoteLanguageAndMeetingDateReachTheFinalPrompt() async throws {
        let gen = FakeGenerator(contextSize: 16384)
        var req = request("SPEAKER_00: hola", style: .factsFirst)
        req.noteLanguage = "ca"
        req.meetingDate = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try await SummaryDriver.run(req, generator: gen)
        XCTAssertEqual(gen.prompts, [
            Prompt.build(transcript: "SPEAKER_00: hola", noteOwner: "Marc", userSpeaker: "SPEAKER_00",
                         style: .factsFirst, meetingDate: req.meetingDate, noteLanguage: "ca")])
    }

    // MARK: reduceToFit

    /// A generator whose map answers keep growing never lets the fold shrink:
    /// folding must stop after one extra round, the notes be truncated, and the
    /// final prompt still fit its budget.
    func testReduceToFitStopsWhenFoldingStopsShrinking() async throws {
        let big = String(repeating: "word ", count: 4000)   // 20K chars per map answer
        let gen = FakeGenerator(contextSize: 4096, respond: { prompt, _ in
            prompt.hasPrefix("You are reading ONE PART") ? big : "# Meeting notes\n\n## Executive summary\nok"
        })
        let text = transcript(chars: 60_000)
        let chunks = EmbeddedSummaryPlanner.chunks(
            transcript: text, budgetTokens: EmbeddedSummaryBudget.map(contextSize: 4096).transcriptTokens).count
        _ = try await SummaryDriver.run(request(text), generator: gen)

        // First-pass map calls + exactly one fold round (it grew, so folding
        // stopped) + the final call — never the full three rounds.
        let merged = EmbeddedSummaryPrompt.merge(partials: Array(repeating: big, count: chunks))
        let foldChunks = EmbeddedSummaryPlanner.chunks(
            transcript: merged, budgetTokens: EmbeddedSummaryBudget.map(contextSize: 4096).transcriptTokens).count
        XCTAssertEqual(gen.prompts.count, chunks + foldChunks + 1)
        let finalPrompt = gen.prompts.last!
        let budget = EmbeddedSummaryBudget.final(contextSize: 4096, noteOwner: "Marc", userSpeaker: "SPEAKER_00")
        XCTAssertLessThanOrEqual(EmbeddedSummaryTokens.estimate(finalPrompt),
                                 4096 - budget.reservedForOutput - budget.safetyMargin)
    }

    /// Folding that does shrink is used: bounded by `maxFoldRounds`.
    func testReduceToFitFoldsShrinkingNotesAtMostThreeRounds() async throws {
        let blob = String(repeating: "alpha beta gamma delta. ", count: 300)   // ~7K chars
        let gen = FakeGenerator(contextSize: 4096, respond: { prompt, _ in
            prompt.hasPrefix("You are reading ONE PART") ? blob : "# Meeting notes\n\n## Executive summary\nok"
        })
        _ = try await SummaryDriver.run(request(transcript(chars: 200_000)), generator: gen)
        let foldCalls = gen.prompts.filter { $0.contains("--- Notes from part") }.count
        XCTAssertGreaterThan(foldCalls, 0, "an oversized merge must be condensed")
        XCTAssertLessThanOrEqual(SummaryDriver.maxFoldRounds, 3)
    }

    // MARK: Token counts

    func testHeuristicPathPassesBudgetedOutputUnchanged() async throws {
        let gen = FakeGenerator(contextSize: 4096, tokenCount: { _ in nil })
        _ = try await SummaryDriver.run(request("SPEAKER_00: hi"), generator: gen)
        XCTAssertEqual(gen.maxTokens, [1800])
    }

    func testMeasuredTokenCountClampsOutput() async throws {
        let gen = FakeGenerator(contextSize: 4096, tokenCount: { _ in 3000 })
        _ = try await SummaryDriver.run(request("SPEAKER_00: hi"), generator: gen)
        XCTAssertEqual(gen.maxTokens, [4096 - 3000 - 128])
    }

    func testMeasuredPromptThatLeavesNoRoomThrows() async {
        let gen = FakeGenerator(contextSize: 4096, tokenCount: { _ in 4000 })
        do {
            _ = try await SummaryDriver.run(request("SPEAKER_00: hi"), generator: gen)
            XCTFail("expected promptTooLong")
        } catch let e as SummaryDriverError {
            XCTAssertEqual(e, .promptTooLong(measured: 4000, contextSize: 4096))
        } catch { XCTFail("\(error)") }
        XCTAssertTrue(gen.prompts.isEmpty, "no generation when the prompt cannot fit")
    }

    // MARK: End-of-turn block budget (review finding)

    /// A transcript that fits the final budget without the block must be
    /// map-reduced once the block's tokens are counted.
    func testEndOfTurnBlockTokensShrinkTheFinalBudget() {
        let plain = EmbeddedSummaryBudget.final(contextSize: 4096, noteOwner: "Marc", userSpeaker: "SPEAKER_00")
        let block = String(repeating: "reminder ", count: 200)   // ~1800 chars
        let withBlock = EmbeddedSummaryBudget.final(contextSize: 4096, noteOwner: "Marc", userSpeaker: "SPEAKER_00",
                                                    extraInstructions: block)
        XCTAssertEqual(plain.transcriptTokens - withBlock.transcriptTokens, EmbeddedSummaryTokens.estimate(block))

        let text = String(transcript(chars: 6000).prefix(Int(Double(plain.transcriptTokens) * 3.0) - 20))
        XCTAssertEqual(EmbeddedSummaryPlanner.plan(transcript: text, contextSize: 4096, noteOwner: "Marc",
                                                   userSpeaker: "SPEAKER_00"), .single)
        if case .single = EmbeddedSummaryPlanner.plan(transcript: text, contextSize: 4096, noteOwner: "Marc",
                                                      userSpeaker: "SPEAKER_00", extraInstructions: block) {
            XCTFail("block tokens must push this transcript into map-reduce")
        }
    }

    func testDriverCountsTheBlockWhenPlanning() async throws {
        let plain = EmbeddedSummaryBudget.final(contextSize: 4096, noteOwner: "Marc", userSpeaker: "SPEAKER_00")
        let block = String(repeating: "reminder ", count: 200)
        let text = String(transcript(chars: 6000).prefix(Int(Double(plain.transcriptTokens) * 3.0) - 20))
        let without = FakeGenerator(contextSize: 4096)
        _ = try await SummaryDriver.run(request(text), generator: without)
        XCTAssertEqual(without.prompts.count, 1)
        let with = FakeGenerator(contextSize: 4096)
        _ = try await SummaryDriver.run(request(text, block: block), generator: with)
        XCTAssertGreaterThan(with.prompts.count, 1)
    }

    /// An output budget far below what was reserved is an error, not a
    /// silently truncated note.
    func testOutputBudgetFarBelowReserveThrows() async {
        let gen = FakeGenerator(contextSize: 4096, tokenCount: { _ in 3500 })   // available 468 < 900
        do {
            _ = try await SummaryDriver.run(request("SPEAKER_00: hi"), generator: gen)
            XCTFail("expected outputBudgetTooSmall")
        } catch { XCTAssertEqual(error as? SummaryDriverError, .outputBudgetTooSmall(available: 468, wanted: 1800)) }
        XCTAssertTrue(gen.prompts.isEmpty)
    }

    // MARK: Errors

    func testContextTooSmallThrows() async {
        let gen = FakeGenerator(contextSize: 600)
        do {
            _ = try await SummaryDriver.run(request(transcript(chars: 6_000)), generator: gen)
            XCTFail("expected contextTooSmall")
        } catch { XCTAssertEqual(error as? SummaryDriverError, .contextTooSmall) }
    }

    func testEmptyGenerationThrowsEmptyResult() async {
        let gen = FakeGenerator(contextSize: 4096, respond: { _, _ in "  \n " })
        do {
            _ = try await SummaryDriver.run(request("SPEAKER_00: hi"), generator: gen)
            XCTFail("expected emptyResult")
        } catch { XCTAssertEqual(error as? SummaryDriverError, .emptyResult) }
    }

    func testEngineErrorsPropagateUntouched() async {
        struct Boom: Error, Equatable {}
        let gen = FakeGenerator(contextSize: 4096, respond: { _, _ in throw Boom() })
        do {
            _ = try await SummaryDriver.run(request("SPEAKER_00: hi"), generator: gen)
            XCTFail("expected Boom")
        } catch { XCTAssertTrue(error is Boom) }
    }

    func testOutputIsTrimmed() async throws {
        let gen = FakeGenerator(contextSize: 4096, respond: { _, _ in "\n\n# Meeting notes\nbody\n\n" })
        let out = try await SummaryDriver.run(request("SPEAKER_00: hi"), generator: gen)
        XCTAssertEqual(out, "# Meeting notes\nbody")
    }

    // MARK: Budget by style

    func testClassicBudgetIsUnchanged() {
        let b = EmbeddedSummaryBudget.final(contextSize: 4096, noteOwner: "Marc", userSpeaker: "SPEAKER_00")
        XCTAssertEqual(b.reservedForOutput, 1800)
        XCTAssertEqual(EmbeddedSummaryBudget.finalOutputTokens(style: .factsFirst), 3500)
    }
}

/// Vikunja #2198 S6: the summariser routing trace line.
final class SummaryRoutingTests: XCTestCase {
    private func line(_ id: String, transcript: String, style: Prompt.Style, lang: String? = nil) -> String {
        SummaryRouting.traceLine(
            model: EmbeddedSummaryModelCatalog.model(id: id), transcript: transcript,
            noteOwner: "Marc", userSpeaker: "SPEAKER_00", style: style, noteLanguage: lang)
    }

    func testGemmaShortTranscriptIsSinglePass() {
        XCTAssertEqual(line("gemma-4-e4b", transcript: "hello there", style: .factsFirst, lang: "ca"),
            "Summariser \u{2014} model=gemma-4-e4b engine=mlx context=16384 style=\(Prompt.Style.factsFirst.rawValue) language=ca; transcript\u{2248}\(EmbeddedSummaryTokens.estimate("hello there")) tokens; plan=single pass")
    }

    func testAppleLongTranscriptIsMapReduce() {
        let long = String(repeating: "word ", count: 20_000)
        let l = line("apple", transcript: long, style: .classic)
        XCTAssertTrue(l.contains("model=apple engine=appleFoundationModels context=4096"), l)
        XCTAssertTrue(l.contains("language=default"), l)
        XCTAssertTrue(l.contains("plan=map-reduce ("), l)
    }

    func testUnknownModelFallsBackToApple() {
        XCTAssertTrue(line("nope", transcript: "x", style: .classic).contains("model=apple"))
    }
}
