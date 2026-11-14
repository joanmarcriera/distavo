import XCTest
@testable import DistavoCore

/// Review C (drive-review-2026-11-09, finding 7): role-term packs (#3950) are English UK-tax/finance terms. A
/// vocabulary prompt is what collapses Barcelona Supercomputing Center Catalan chunks (#3579), so a participants
/// line naming an accountant must not put an English vocabulary into a Catalan (or any non-English) meeting.
/// Synthetic participants only.
final class RoleTermLanguageTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        root = TestTemp.root.appendingPathComponent("rtl-\(UUID().uuidString)")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var vocab: [[String]] = []
        func add(_ v: [String]) { lock.lock(); vocab.append(v); lock.unlock() }
        var first: [String] { lock.lock(); defer { lock.unlock() }; return vocab.first ?? [] }
    }

    /// Process one recording whose participants line names an accountant; returns the vocabulary the engine saw.
    private func vocabularySeen(language: String, override: LanguageOverride? = nil) async throws -> [String] {
        // A fresh folder per call: a test may process several recordings in a row.
        let dir = root.appendingPathComponent(UUID().uuidString)
        let rec = dir.appendingPathComponent("recordings"), work = dir.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: rec, withIntermediateDirectories: true)
        let url = rec.appendingPathComponent("Meeting 2026-10-05 10.00.00.wav")
        try Data([0, 1, 2, 3]).write(to: url)
        var cfg = Config()
        cfg.recordingsDir = rec.path; cfg.notesDir = dir.appendingPathComponent("notes").path; cfg.workDir = work.path
        cfg.transcribe.language = language
        let base = DistavoState.baseFor(recordingsDir: rec, path: url)
        try SpeakerHints(participants: "Sam (accountant), Marc (me)").save(workDir: work, base: base)
        try override?.save(workDir: work, base: base)
        let seen = Seen()
        let deps = PipelineDeps(
            convertToWav: { _, dest in try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true); try Data([0]).write(to: dest) },
            transcribe: { _, tc in seen.add(tc.vocabulary); return ["segments": [["speaker": "SPEAKER_00", "text": "hello world"]]] },
            ollamaReachable: { _ in true },
            summarise: { _, _, _, _ in PipelineTests.validNote },
            audioDurationSeconds: { _ in 1800 })
        let r = await Pipeline.processOne(path: url, config: cfg, deps: deps, stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(r.status, .done, r.message)
        return seen.first
    }

    func testEnglishConfigKeepsRoleTerms() async throws {
        let v = try await vocabularySeen(language: "en")
        XCTAssertTrue(v.contains("PAYE"), "\(v)")
    }

    func testAutoLanguageKeepsRoleTermsToday() async throws {
        let v = try await vocabularySeen(language: "auto")
        XCTAssertTrue(v.contains("PAYE"), "\(v)")
    }

    func testConfiguredCatalanOrSpanishGetsNoRoleTerms() async throws {
        for code in ["ca", "es"] {
            let v = try await vocabularySeen(language: code)
            XCTAssertFalse(v.contains("PAYE"), "\(code): \(v)")
            XCTAssertTrue(v.contains("Sam"), "the owner's own participant names are still seeded: \(v)")
        }
    }

    func testNonEnglishOverrideWinsOverAutoAndOverEnglish() async throws {
        for configured in ["auto", "en"] {
            let v = try await vocabularySeen(language: configured, override: LanguageOverride(code: "ca"))
            XCTAssertFalse(v.contains("PAYE"), "\(configured): \(v)")
        }
    }

    func testEnglishOverrideKeepsRoleTermsEvenWhenConfiguredNonEnglish() async throws {
        let v = try await vocabularySeen(language: "ca", override: LanguageOverride(code: "en"))
        XCTAssertTrue(v.contains("PAYE"), "\(v)")
    }

    func testNoteOnlyOverrideDoesNotChangeTheSpokenLanguage() async throws {
        let v = try await vocabularySeen(language: "auto", override: LanguageOverride(noteLanguage: "ca"))
        XCTAssertTrue(v.contains("PAYE"), "\(v)")
    }

    // MARK: the rule itself

    func testAppliesToRule() {
        for ok in ["en", "EN", "en-GB", "en_US", "auto", "", " auto "] {
            XCTAssertTrue(RoleTermPacks.appliesTo(configuredLanguage: ok), "configured \(ok)")
        }
        for no in ["ca", "es", "fr", "english"] {
            XCTAssertFalse(RoleTermPacks.appliesTo(configuredLanguage: no), "configured \(no)")
        }
        XCTAssertFalse(RoleTermPacks.appliesTo(configuredLanguage: "auto", override: LanguageOverride(code: "ca")))
        XCTAssertTrue(RoleTermPacks.appliesTo(configuredLanguage: "ca", override: LanguageOverride(code: "en")))
        XCTAssertTrue(RoleTermPacks.appliesTo(configuredLanguage: "auto", override: LanguageOverride(noteLanguage: "ca")))
        XCTAssertTrue(RoleTermPacks.appliesTo(configuredLanguage: "auto", override: nil))
    }

    func testSpeakerHintsRoleTermsHonoursTheRule() {
        let hints = SpeakerHints(participants: "Sam (accountant)")
        XCTAssertFalse(hints.roleTerms(configuredLanguage: "en", override: nil).isEmpty)
        XCTAssertTrue(hints.roleTerms(configuredLanguage: "ca", override: nil).isEmpty)
        XCTAssertFalse(hints.roleTerms.isEmpty, "the plain property is unchanged")
    }
}
