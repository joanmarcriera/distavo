import XCTest
@testable import DistavoCore

/// Vikunja #3585: a Catalan/Spanish note must be written in that language: the instruction opens and
/// closes the prompt, the answer is checked, and a wrong-language answer is retried once.
final class NoteLanguageCheckTests: XCTestCase {

    private let catalan = """
    # Meeting notes

    ## Executive summary
    La reunió va tractar sobre els projectes de l'empresa i els terrenys amb potència elèctrica. Els participants \
    han explicat que també volen entendre quin procés pot ajudar a fer més diners amb aquest terreny. Això és molt \
    important perquè els costos són alts i les decisions es prenen entre tots, després de cada trobada. Hem acordat \
    que cada persona farà la seva part i que van estat revisant els números amb més cura que mai.
    """
    private let english = """
    # Meeting notes

    ## Executive summary
    The meeting was about the projects of the company and the land with electrical capacity. The participants \
    explained that they also want to understand which process can help to make more money with this land. This is very \
    important because the costs are high and the decisions will be taken between everyone, after each meeting. We have \
    agreed that each person will do their part and that they were reviewing the numbers with more care than ever.
    """
    private let spanish = """
    # Meeting notes

    ## Executive summary
    La reunión trató sobre los proyectos de la empresa y los terrenos con potencia eléctrica. Los participantes \
    explicaron que también quieren entender qué proceso puede ayudar a hacer más dinero con este terreno. Esto es muy \
    importante porque los costes son altos y las decisiones se toman entre todos, después de cada reunión. Hemos acordado \
    que cada persona hará su parte y que fueron revisando los números con más cuidado que nunca.
    """

    func testDetect() {
        XCTAssertEqual(NoteLanguageCheck.detect(catalan), "ca")
        XCTAssertEqual(NoteLanguageCheck.detect(english), "en")
        XCTAssertEqual(NoteLanguageCheck.detect(spanish), "es")
    }

    func testEnglishBodyIsFlaggedWhenCatalanWasRequested() {
        XCTAssertTrue(NoteLanguageCheck.ignored(requested: "ca", in: english))
        XCTAssertTrue(NoteLanguageCheck.ignored(requested: "es", in: english))
        XCTAssertTrue(NoteLanguageCheck.ignored(requested: "ca", in: spanish))
        XCTAssertFalse(NoteLanguageCheck.ignored(requested: "ca", in: catalan))
        XCTAssertFalse(NoteLanguageCheck.ignored(requested: "es", in: spanish))
    }

    func testNothingIsFlaggedWhenItCannotBeJudged() {
        XCTAssertFalse(NoteLanguageCheck.ignored(requested: nil, in: english), "English requested = no check")
        XCTAssertFalse(NoteLanguageCheck.ignored(requested: "fr", in: english), "only ca/es have a check")
        XCTAssertFalse(NoteLanguageCheck.ignored(requested: "ca", in: "# Meeting notes\n\n## Context\nToo short to tell."))
        // Headings, tables and ledger rows (quotes in the spoken language) are not prose.
        let tableOnly = "## Facts ledger\n- the and with | S | \"the and with this that\" | the\n| the | and | with |\n"
        XCTAssertNil(NoteLanguageCheck.detect(tableOnly))
    }

    func testFooterNoteNamesBothLanguages() {
        XCTAssertEqual(NoteLanguageCheck.footerNote(requested: "ca", text: english),
                       "Note language: Catalan (requested) / English (model ignored)")
        XCTAssertNil(NoteLanguageCheck.footerNote(requested: "ca", text: catalan))
    }

    // MARK: Prompt

    func testCatalanInstructionOpensAndClosesThePrompt() {
        let p = Prompt.build(transcript: "TRANSCRIPT-BODY", noteOwner: "Marc", userSpeaker: "u",
                             style: .factsFirst, noteLanguage: "ca")
        let line = "Escriu les notes en català"
        XCTAssertTrue(p.hasPrefix(line))
        XCTAssertTrue(p.contains("\nReminder: " + line))
        XCTAssertGreaterThan(p.components(separatedBy: line).count - 1, 2, "opening, the rule, the reminder")
        XCTAssertTrue(p.range(of: "TRANSCRIPT-BODY")!.upperBound < p.range(of: "Reminder:")!.lowerBound)
    }

    func testEnglishPromptIsUntouched() {
        for style in [Prompt.Style.classic, .factsFirst] {
            let p = Prompt.build(transcript: "T", noteOwner: "Marc", userSpeaker: "u", style: style, noteLanguage: nil)
            XCTAssertFalse(p.contains("Reminder:"))
            XCTAssertTrue(p.hasPrefix(style == .factsFirst ? "Meeting metadata" : "You are analysing"))
        }
    }

    // MARK: Pipeline retry

    private func run(replies: [String], language: String = "ca") async throws -> (notes: String, calls: Int, instructions: [String?]) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("distavo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        var cfg = Config()
        cfg.recordingsDir = dir.appendingPathComponent("rec").path
        cfg.notesDir = dir.appendingPathComponent("notes").path
        cfg.workDir = dir.appendingPathComponent("work").path
        cfg.summarise.noteLanguage = language
        for d in [cfg.recordingsDir, cfg.notesDir, cfg.workDir] { try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true) }
        let input = URL(fileURLWithPath: cfg.recordingsDir).appendingPathComponent("demo.opus")
        try Data(repeating: 1, count: 64).write(to: input)
        let calls = Box<Int>(0), seen = Box<[String?]>([])
        let deps = PipelineDeps(
            convertToWav: { _, dest in
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data([0]).write(to: dest)
            },
            transcribe: { _, _ in ["segments": [["speaker": "SPEAKER_00", "text": "hola bon dia"]]] },
            ollamaReachable: { _ in true },
            summarise: { _, _, _, context in
                let n = calls.value; calls.set(n + 1); seen.set(seen.value + [context.customInstruction])
                return replies[min(n, replies.count - 1)]
            },
            audioDurationSeconds: { _ in 60 })
        let r = await Pipeline.processOne(path: input, config: cfg, deps: deps, stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(r.status, .done, r.message)
        return (try String(contentsOf: try XCTUnwrap(r.notePath)), calls.value, seen.value)
    }

    func testWrongLanguageIsRetriedOnceAndTheCatalanAnswerWins() async throws {
        let out = try await run(replies: [english, catalan])
        XCTAssertEqual(out.calls, 2)
        XCTAssertNil(out.instructions[0])
        XCTAssertTrue(out.instructions[1]?.contains("wrong language") == true)
        XCTAssertTrue(out.notes.contains("La reunió va tractar"))
        XCTAssertFalse(out.notes.contains("model ignored"))
    }

    func testStillWrongAfterTheRetryIsKeptWithAFooterNote() async throws {
        let out = try await run(replies: [english, english])
        XCTAssertEqual(out.calls, 2, "one retry, never more")
        XCTAssertTrue(out.notes.contains("Note language: Catalan (requested) / English (model ignored)"), out.notes)
    }

    func testRightLanguageAndEnglishRequestsAreNotRetried() async throws {
        let rightLanguage = try await run(replies: [catalan])
        let englishRequested = try await run(replies: [english], language: "en")
        XCTAssertEqual(rightLanguage.calls, 1)
        XCTAssertEqual(englishRequested.calls, 1)
    }
}

private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock(); private var v: T
    init(_ v: T) { self.v = v }
    func set(_ x: T) { lock.lock(); v = x; lock.unlock() }
    var value: T { lock.lock(); defer { lock.unlock() }; return v }
}
