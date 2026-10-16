import XCTest
@testable import DistavoCore

/// Vikunja #3584: per-meeting terms, the Catalan IT replacement pack, and a glossary that is a spelling
/// aid and never meeting content.
final class MeetingVocabularyTests: XCTestCase {

    func testPackIsOffByDefaultAndOptInAddsRulesAfterTheUsersOwn() {
        var t = TranscribeConfig()
        t.replacements = [ReplacementRule(from: "sonic world", to: "My Own Spelling")]
        XCTAssertEqual(t.effectiveReplacements, t.replacements, "nothing without opting in")
        t.replacementPacks = ["ca_it", "no_such_pack"]
        let rules = t.effectiveReplacements
        XCTAssertEqual(rules.first?.to, "My Own Spelling")
        XCTAssertEqual(rules.count, 1 + ReplacementPacks.catalanIT.rules.count)
        // The user's rule is applied first, so it wins over the pack's "SonicWall".
        XCTAssertEqual(CompiledReplacements(rules).apply("el sonic world"), "el My Own Spelling")
    }

    func testPackCorrectsTheFieldTestMisreadings() {
        let rules = CompiledReplacements(ReplacementPacks.rules(for: ["ca_it"]))
        let heard = "Tenim l'rp nou i el Sonic World amb Entre ID. Fem becups cada dia, el fèrgol i el Business Centre."
        let fixed = rules.apply(heard)
        for gone in ["l'rp", "sonic world", "entre id", "becups", "fèrgol", "business centre"] {
            XCTAssertFalse(fixed.lowercased().contains(gone), "\(gone) -> \(fixed)")
        }
        for kept in ["l'ERP", "SonicWall", "Entra ID", "backups", "firewall", "Business Central"] {
            XCTAssertTrue(fixed.contains(kept), "\(kept) in \(fixed)")
        }
        // Real words are left alone.
        XCTAssertEqual(rules.apply("Vam viatjar a Haití amb un entre amics."), "Vam viatjar a Haití amb un entre amics.")
    }

    func testConfigRoundTripAndOldConfigs() throws {
        XCTAssertEqual(try JSONDecoder().decode(TranscribeConfig.self, from: Data("{}".utf8)).replacementPacks, [])
        let c = try JSONDecoder().decode(TranscribeConfig.self, from: Data(#"{"replacement_packs": ["ca_it"]}"#.utf8))
        XCTAssertEqual(c.replacementPacks, ["ca_it"])
        let bad = try JSONDecoder().decode(TranscribeConfig.self, from: Data(#"{"replacement_packs": 5}"#.utf8))
        XCTAssertEqual(bad.replacementPacks, [], "a wrong type never fails the config")
    }

    func testSpeakerHintsCarryMeetingTermsAndOldSidecarsStillLoad() throws {
        let hints = SpeakerHints(count: nil, participants: nil, terms: ["WatchGuard", " ", "Entra ID"])
        XCTAssertFalse(hints.isEmpty)
        XCTAssertTrue(SpeakerHints(count: nil, participants: nil, terms: [" ", ","]).isEmpty)
        let data = try JSONEncoder().encode(hints)
        XCTAssertEqual(try JSONDecoder().decode(SpeakerHints.self, from: data), hints)
        let old = try JSONDecoder().decode(SpeakerHints.self, from: Data(#"{"count": 2, "participants": "A"}"#.utf8))
        XCTAssertNil(old.terms)
    }

    func testGlossaryIsAskedAsASpellingAidNeverAsFacts() {
        let p = Prompt.build(transcript: "T", noteOwner: "Marc", userSpeaker: "u", style: .factsFirst, glossary: ["Slurm", "Bull"])
        XCTAssertTrue(p.contains("only where a similar word is in the transcript"))
        XCTAssertTrue(p.contains("never list one as a fact, speaker or topic unless the transcript mentions it"))
        let none = Prompt.build(transcript: "T", noteOwner: "Marc", userSpeaker: "u", style: .factsFirst)
        XCTAssertFalse(none.contains("Spelling aid, not meeting content"), "no glossary, no block")
    }

    func testPipelineMergesMeetingTermsAheadOfGlobalAndAppliesPacks() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("distavo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        var cfg = Config()
        cfg.recordingsDir = dir.appendingPathComponent("rec").path
        cfg.notesDir = dir.appendingPathComponent("notes").path
        cfg.workDir = dir.appendingPathComponent("work").path
        cfg.transcribe.vocabulary = ["GlobalTerm"]
        cfg.transcribe.replacementPacks = ["ca_it"]
        for d in [cfg.recordingsDir, cfg.notesDir, cfg.workDir] { try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true) }
        let input = URL(fileURLWithPath: cfg.recordingsDir).appendingPathComponent("demo.opus")
        try Data(repeating: 1, count: 64).write(to: input)
        try SpeakerHints(count: nil, participants: nil, terms: ["MeetingTerm"]).save(workDir: URL(fileURLWithPath: cfg.workDir), base: "demo")
        let seenVocab = Lock<[String]>([]), seenGlossary = Lock<[String]>([])
        let deps = PipelineDeps(
            convertToWav: { _, dest in
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data([0]).write(to: dest)
            },
            transcribe: { _, t in
                seenVocab.set(t.vocabulary)
                return ["segments": [["speaker": "SPEAKER_00", "text": "Tenim el Sonic World i els becups"]]]
            },
            ollamaReachable: { _ in true },
            summarise: { transcript, _, _, context in
                seenGlossary.set(context.glossary)
                XCTAssertTrue(transcript.contains("SonicWall") && transcript.contains("backups"), transcript)
                return PipelineTests.validNote
            },
            audioDurationSeconds: { _ in 60 })
        let r = await Pipeline.processOne(path: input, config: cfg, deps: deps, stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(r.status, .done, r.message)
        XCTAssertEqual(seenVocab.value, ["MeetingTerm", "GlobalTerm"])
        XCTAssertEqual(seenGlossary.value, ["MeetingTerm", "GlobalTerm"])
    }
}

private final class Lock<T>: @unchecked Sendable {
    private let l = NSLock(); private var v: T
    init(_ v: T) { self.v = v }
    func set(_ x: T) { l.lock(); v = x; l.unlock() }
    var value: T { l.lock(); defer { l.unlock() }; return v }
}
