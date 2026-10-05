import XCTest
@testable import DistavoCore

/// Custom vocabulary + replacement dictionary (Vikunja #2939): the pure logic,
/// the byte-identical-when-empty guarantees, the config migration, the WhisperX
/// request, the summary budget and an end-to-end pipeline run.
final class VocabularyTests: XCTestCase {

    private func rules(_ pairs: (String, String)...) -> [ReplacementRule] {
        pairs.map { ReplacementRule(from: $0.0, to: $0.1) }
    }
    private func apply(_ text: String, _ r: [ReplacementRule]) -> String {
        Vocabulary.applyReplacements(text, rules: r)
    }

    // MARK: Replacement engine

    func testReplacesCaseInsensitivelyAsWholeWords() {
        XCTAssertEqual(apply("We run SLUM and slum today.", rules(("slum", "Slurm"))),
                       "We run Slurm and Slurm today.")
    }

    func testLeavesUnrelatedWordsAndSubstringsAlone() {
        let text = "The cat found a category of concatenated scatter, not a bobcat."
        XCTAssertEqual(apply(text, rules(("cat", "dog"))), text.replacingOccurrences(of: "The cat", with: "The dog"))
        XCTAssertEqual(apply("category concatenate", rules(("cat", "dog"))), "category concatenate")
    }

    func testPunctuationIsABoundary() {
        XCTAssertEqual(apply("slum, slum. (slum) slum's", rules(("slum", "Slurm"))),
                       "Slurm, Slurm. (Slurm) Slurm's")
    }

    func testAccentedCatalanAndSpanishWords() {
        // "Mark" must not match inside an accented word, and accents are word characters.
        XCTAssertEqual(apply("Hola Maria, la Mària i en Marià", rules(("Mària", "Maria"))),
                       "Hola Maria, la Maria i en Marià")
        XCTAssertEqual(apply("el café, cafeína", rules(("café", "cafè"))), "el cafè, cafeína")
        XCTAssertEqual(apply("ÉPOCA época", rules(("época", "època"))), "època època")
        // Decomposed (NFD) accent: the combining mark counts as part of the word.
        let nfd = "Mari\u{0301}a"
        XCTAssertEqual(apply(nfd, rules(("Mari", "X"))), nfd)
    }

    func testMultiWordPhrases() {
        XCTAssertEqual(apply("We use Ember EBI and ember  ebi daily; remember ebi.",
                             rules(("ember ebi", "EMBL-EBI"))),
                       "We use EMBL-EBI and EMBL-EBI daily; remember ebi.")
    }

    func testRulesApplyInOrder() {
        XCTAssertEqual(apply("a", rules(("a", "b"), ("b", "c"))), "c")
        XCTAssertEqual(apply("a", rules(("b", "c"), ("a", "b"))), "b")
    }

    func testEmptyFromIsIgnoredAndReplacementIsLiteral() {
        let text = "nothing changes here"
        XCTAssertEqual(apply(text, rules(("", "x"), ("   ", "y"))), text)
        XCTAssertEqual(apply("price", rules(("price", "$1 \\0 $&"))), "$1 \\0 $&")
        XCTAssertEqual(apply("c++ and cpp", rules(("c++", "C++"))), "C++ and cpp")
    }

    func testEmptyRulesLeaveTextUntouched() {
        let text = "[SPEAKER_00]\nhello"
        XCTAssertEqual(apply(text, []), text)
    }

    // MARK: Cleaner

    func testCleanerEmptyMapIsByteIdenticalAndHeadersAreSafe() {
        let segs = [Segment(speaker: "SPEAKER_00", text: "we run slum"),
                    Segment(speaker: "SPEAKER_01", text: "ok")]
        let baseline = TranscriptCleaner.clean(segs)
        XCTAssertEqual(TranscriptCleaner.clean(segs, replacements: []), baseline)
        let fixed = TranscriptCleaner.clean(segs, replacements: rules(("slum", "Slurm"), ("speaker_00", "X")))
        XCTAssertEqual(fixed, "[SPEAKER_00]\nwe run Slurm\n\n[SPEAKER_01]\nok")
    }

    // MARK: Transcriber prompt

    func testTranscriberPromptEmptyAndBasic() {
        XCTAssertEqual(Vocabulary.transcriberPrompt([]), "")
        XCTAssertEqual(Vocabulary.transcriberPrompt(["  ", "", ","]), "")
        XCTAssertEqual(Vocabulary.transcriberPrompt(["Slurm", " slurm ", "EMBL-EBI", "Lustre, Bull"]),
                       "Slurm, EMBL-EBI, Lustre, Bull.")
    }

    func testTranscriberPromptIsBoundedAndDeterministic() {
        let terms = (0..<400).map { "Term\($0)" }
        let prompt = Vocabulary.transcriberPrompt(terms)
        XCTAssertLessThanOrEqual(prompt.count, Vocabulary.maxTranscriberPromptCharacters + 1)
        XCTAssertTrue(prompt.hasPrefix("Term0, Term1, Term2,"))
        XCTAssertEqual(prompt, Vocabulary.transcriberPrompt(terms))
        // Never cuts a term in half: the prompt is "whole terms, comma separated, '.'".
        for piece in prompt.dropLast().components(separatedBy: ", ") {
            XCTAssertTrue(terms.contains(piece), "\(piece) is a cut term")
        }
        // A single over-long term yields nothing rather than a truncated one.
        XCTAssertEqual(Vocabulary.transcriberPrompt([String(repeating: "x", count: 600)]), "")
    }

    // MARK: Summary prompt

    private func build(style: Prompt.Style, glossary: [String]? = nil) -> String {
        if let glossary {
            return Prompt.build(transcript: "T", noteOwner: "Marc", userSpeaker: "SPEAKER_00",
                                style: style, glossary: glossary)
        }
        return Prompt.build(transcript: "T", noteOwner: "Marc", userSpeaker: "SPEAKER_00", style: style)
    }

    func testEmptyGlossaryLeavesPromptByteIdentical() {
        for style in [Prompt.Style.classic, .factsFirst] {
            let baseline = build(style: style)
            XCTAssertEqual(build(style: style, glossary: []), baseline)
            XCTAssertEqual(build(style: style, glossary: ["", "  ,"]), baseline)
            XCTAssertFalse(baseline.contains("spell exactly"))
        }
        // And the baseline really is the untouched template.
        let expectedClassic = Prompt.template
            .replacingOccurrences(of: "{note_owner}", with: "Marc")
            .replacingOccurrences(of: "{user_speaker}", with: "SPEAKER_00")
            .replacingOccurrences(of: "{transcript_text}", with: "T")
        XCTAssertEqual(build(style: .classic), expectedClassic)
    }

    func testGlossaryAddsOneLineInBothStyles() {
        for style in [Prompt.Style.classic, .factsFirst] {
            let withTerms = build(style: style, glossary: ["Slurm", "EMBL-EBI"])
            let base = build(style: style)
            let line = "Names and terms to spell exactly as written here (speech-to-text may have misspelled them): Slurm, EMBL-EBI\n"
            XCTAssertTrue(withTerms.contains(line))
            XCTAssertEqual(withTerms.replacingOccurrences(of: line, with: ""), base)
        }
    }

    func testGlossaryIsCappedInThePrompt() {
        let many = (0..<500).map { "Term\($0)" }
        XCTAssertLessThanOrEqual(Vocabulary.summaryTerms(many).count, Vocabulary.maxSummaryTerms)
        let prompt = build(style: .classic, glossary: many)
        XCTAssertFalse(prompt.contains("Term100"))
    }

    func testGlossaryCountsInTheOnDeviceBudget() {
        let plain = EmbeddedSummaryBudget.final(contextSize: 4096, noteOwner: "Marc", userSpeaker: "SPEAKER_00")
        XCTAssertEqual(EmbeddedSummaryBudget.final(contextSize: 4096, noteOwner: "Marc",
                                                   userSpeaker: "SPEAKER_00", glossary: []).instructionTokens,
                       plain.instructionTokens)
        let withTerms = EmbeddedSummaryBudget.final(contextSize: 4096, noteOwner: "Marc",
                                                    userSpeaker: "SPEAKER_00",
                                                    glossary: ["Slurm", "Lustre", "EMBL-EBI"])
        XCTAssertGreaterThan(withTerms.instructionTokens, plain.instructionTokens)
        // Even a huge glossary cannot eat the window: the cap bounds the growth.
        let huge = EmbeddedSummaryBudget.final(contextSize: 4096, noteOwner: "Marc", userSpeaker: "SPEAKER_00",
                                               glossary: (0..<500).map { "Term\($0)" })
        XCTAssertLessThan(huge.instructionTokens - plain.instructionTokens, 200)
    }

    // MARK: Config migration

    func testOldConfigDecodesToEmptyVocabulary() throws {
        let cfg = try JSONDecoder().decode(
            Config.self, from: Data(#"{"transcribe": {"backend": "server", "model": "medium"}}"#.utf8))
        XCTAssertEqual(cfg.transcribe.vocabulary, [])
        XCTAssertEqual(cfg.transcribe.replacements, [])
        let none = try JSONDecoder().decode(Config.self, from: Data("{}".utf8))
        XCTAssertEqual(none.transcribe.vocabulary, [])
        XCTAssertEqual(none.transcribe.replacements, [])
        XCTAssertEqual(Config.recommendedForThisMac().transcribe.vocabulary, [])
        XCTAssertEqual(Config.recommendedForThisMac().transcribe.replacements, [])
    }

    func testVocabularyRoundTripsThroughJSON() throws {
        var cfg = Config()
        cfg.transcribe.vocabulary = ["Slurm", "Marc"]
        cfg.transcribe.replacements = rules(("slum", "Slurm"))
        let data = try JSONEncoder().encode(cfg)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"vocabulary\""))
        XCTAssertTrue(text.contains("\"replacements\""))
        let back = try JSONDecoder().decode(Config.self, from: data)
        XCTAssertEqual(back.transcribe.vocabulary, ["Slurm", "Marc"])
        XCTAssertEqual(back.transcribe.replacements, rules(("slum", "Slurm")))
    }

    // MARK: WhisperX request

    private func whisperXQuery(vocabulary: [String]) async throws -> String {
        let wav = FileManager.default.temporaryDirectory.appendingPathComponent("distavo-\(UUID().uuidString).wav")
        try Data([0, 1]).write(to: wav)
        defer { try? FileManager.default.removeItem(at: wav) }
        let box = QueryBox()
        let session = MockURLProtocol.session { req in
            box.query = req.url?.query ?? ""
            return try MockURLProtocol.ok(req.url!, json: ["segments": [[String: Any]]()])
        }
        var cfg = TranscribeConfig()
        cfg.whisperxURL = "http://host:9000"
        cfg.vocabulary = vocabulary
        _ = try await WhisperXClient(session: session).transcribe(wavURL: wav, config: cfg)
        return box.query
    }

    func testWhisperXSendsInitialPromptOnlyWhenGlossaryIsNonEmpty() async throws {
        let empty = try await whisperXQuery(vocabulary: [])
        XCTAssertFalse(empty.contains("initial_prompt"))
        let blank = try await whisperXQuery(vocabulary: ["  "])
        XCTAssertEqual(blank, empty)
        let withTerms = try await whisperXQuery(vocabulary: ["Slurm", "EMBL-EBI"])
        XCTAssertTrue(withTerms.hasPrefix(empty), "existing params must be unchanged and first")
        XCTAssertTrue(withTerms.contains("initial_prompt=Slurm,%20EMBL-EBI.")
                      || withTerms.contains("initial_prompt=Slurm, EMBL-EBI."), withTerms)
    }

    // MARK: End to end

    /// A term mis-heard at baseline ("slum") is spelled correctly in the
    /// transcript the summariser sees and the saved transcript, and the
    /// glossary reaches the summary prompt; the transcriber stub also proves
    /// the vocabulary arrives through the config seam.
    func testMisheardTermIsFixedInTranscriptAndPrompt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("distavo-vocab-\(UUID().uuidString)")
        let rec = root.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: rec, withIntermediateDirectories: true)
        let input = rec.appendingPathComponent("demo.opus")
        try Data([0, 1, 2, 3]).write(to: input)
        var cfg = Config()
        cfg.recordingsDir = rec.path
        cfg.notesDir = root.appendingPathComponent("notes").path
        cfg.workDir = root.appendingPathComponent("work").path
        cfg.transcribe.vocabulary = ["Slurm"]
        cfg.transcribe.replacements = [ReplacementRule(from: "slum", to: "Slurm")]

        let seen = SeenBox()
        let deps = PipelineDeps(
            convertToWav: { _, dest in
                try FileManager.default.createDirectory(
                    at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data([0]).write(to: dest)
            },
            transcribe: { _, tcfg in
                seen.vocabulary = tcfg.vocabulary
                return ["segments": [["speaker": "SPEAKER_00", "text": "We queue jobs on the Slum cluster"]]]
            },
            ollamaReachable: { _ in true },
            summarise: { transcript, _, _, context in
                seen.transcript = transcript
                seen.prompt = context.prompt(transcript: transcript)
                return PipelineTests.validNote
            })
        let result = await Pipeline.processOne(path: input, config: cfg, deps: deps, stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(seen.vocabulary, ["Slurm"])
        XCTAssertTrue(seen.transcript.contains("Slurm cluster"))
        XCTAssertFalse(seen.transcript.contains("Slum"))
        XCTAssertTrue(seen.prompt.contains("spell exactly as written here"))
        XCTAssertTrue(seen.prompt.contains(": Slurm\n"))
        let saved = try String(contentsOf: URL(fileURLWithPath: cfg.workDir)
            .appendingPathComponent("demo.transcript.clean.txt"), encoding: .utf8)
        XCTAssertTrue(saved.contains("Slurm cluster"))
    }
}

private final class QueryBox: @unchecked Sendable {
    var query = ""
}

private final class SeenBox: @unchecked Sendable {
    var vocabulary: [String] = []
    var transcript = ""
    var prompt = ""
}
