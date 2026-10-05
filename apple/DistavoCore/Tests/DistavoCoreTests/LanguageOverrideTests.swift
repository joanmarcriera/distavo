import XCTest
@testable import DistavoCore

/// Vikunja #2202: the sidecar an owner's explicit language confirmation/
/// override writes after Stop. Modelled on `SpeakerHints` — see `StateTests`
/// for that sidecar's own round-trip coverage.
final class LanguageOverrideTests: XCTestCase {
    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("distavo-langoverride-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testMissingSidecarReturnsNil() {
        XCTAssertNil(LanguageOverride.load(workDir: tempDir(), base: "no-such-recording"))
    }

    func testSaveThenLoadRoundTrips() throws {
        let workDir = tempDir()
        try LanguageOverride(code: "ca").save(workDir: workDir, base: "Meeting_2026-09-24_10.00.00")
        let loaded = LanguageOverride.load(workDir: workDir, base: "Meeting_2026-09-24_10.00.00")
        XCTAssertEqual(loaded?.code, "ca")
    }

    /// A corrupt/unparsable sidecar falls back to nil — the router then runs
    /// its own detection exactly as if #2202 didn't exist — never throws.
    func testCorruptSidecarReturnsNilNotThrows() throws {
        let workDir = tempDir()
        let url = LanguageOverride.url(workDir: workDir, base: "demo")
        try "{not json".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertNil(LanguageOverride.load(workDir: workDir, base: "demo"))
    }

    /// "auto" (or empty) is never a meaningful override — Automatic means no
    /// sidecar at all, so a hand-edited or stale file carrying it is treated
    /// the same as no override.
    func testAutomaticOrEmptyCodeIsTreatedAsNoOverride() throws {
        let workDir = tempDir()
        try LanguageOverride(code: EmbeddedModelCatalog.automaticID).save(workDir: workDir, base: "a")
        XCTAssertNil(LanguageOverride.load(workDir: workDir, base: "a"))
        try LanguageOverride(code: "").save(workDir: workDir, base: "b")
        XCTAssertNil(LanguageOverride.load(workDir: workDir, base: "b"))
    }

    func testDifferentRecordingsHaveIndependentSidecars() throws {
        let workDir = tempDir()
        try LanguageOverride(code: "ca").save(workDir: workDir, base: "one")
        try LanguageOverride(code: "es").save(workDir: workDir, base: "two")
        XCTAssertEqual(LanguageOverride.load(workDir: workDir, base: "one")?.code, "ca")
        XCTAssertEqual(LanguageOverride.load(workDir: workDir, base: "two")?.code, "es")
    }

    // MARK: sourceBase (variant base stripping)

    func testSourceBaseStripsVariantSuffix() {
        XCTAssertEqual(LanguageOverride.sourceBase(from: "Meeting_2026-09-24@large-v3-turbo-ca"), "Meeting_2026-09-24")
        XCTAssertEqual(LanguageOverride.sourceBase(from: "Meeting_2026-09-24"), "Meeting_2026-09-24")
    }

    // MARK: applying (review finding — #2202/#2205 interaction, AppPipelineDeps)

    func testApplyingUsesOverrideWhenConfigIsAutomatic() throws {
        let workDir = tempDir()
        try LanguageOverride(code: "ca").save(workDir: workDir, base: "meeting")
        var config = TranscribeConfig()
        config.language = EmbeddedModelCatalog.automaticID
        let applied = LanguageOverride.applying(to: config, workDir: workDir, wavBase: "meeting")
        XCTAssertEqual(applied.language, "ca", "the router should prefer the override over automatic")
    }

    func testApplyingLeavesAnExplicitLanguageAlone() throws {
        // The #2205 retry-transcribe-bigger action (and any fixed Settings
        // language) resolves its own language before calling the pipeline;
        // the sidecar must not silently replace it.
        let workDir = tempDir()
        try LanguageOverride(code: "ca").save(workDir: workDir, base: "meeting")
        var config = TranscribeConfig()
        config.language = "es"
        let applied = LanguageOverride.applying(to: config, workDir: workDir, wavBase: "meeting")
        XCTAssertEqual(applied.language, "es")
    }

    func testApplyingFallsBackToDetectionWhenSidecarIsMissing() {
        var config = TranscribeConfig()
        config.language = EmbeddedModelCatalog.automaticID
        let applied = LanguageOverride.applying(to: config, workDir: tempDir(), wavBase: "no-such-recording")
        XCTAssertEqual(applied.language, EmbeddedModelCatalog.automaticID)
    }

    func testApplyingFallsBackToDetectionWhenSidecarIsCorrupt() throws {
        let workDir = tempDir()
        try "{not json".write(to: LanguageOverride.url(workDir: workDir, base: "meeting"),
                              atomically: true, encoding: .utf8)
        var config = TranscribeConfig()
        config.language = EmbeddedModelCatalog.automaticID
        let applied = LanguageOverride.applying(to: config, workDir: workDir, wavBase: "meeting")
        XCTAssertEqual(applied.language, EmbeddedModelCatalog.automaticID)
    }

    // MARK: per-recording note language (Vikunja #2956)

    /// A sidecar written before #2956 (only `code`) decodes unchanged: no note override.
    func testOldSidecarDecodesWithNoNoteLanguage() throws {
        let workDir = tempDir()
        try #"{"code":"ca"}"#.write(to: LanguageOverride.url(workDir: workDir, base: "old"),
                                    atomically: true, encoding: .utf8)
        let loaded = LanguageOverride.load(workDir: workDir, base: "old")
        XCTAssertEqual(loaded, LanguageOverride(code: "ca"))
        XCTAssertNil(loaded?.noteLanguage)
    }

    /// A code-only save does not grow a note_language key (old readers see the same file shape).
    func testCodeOnlySaveOmitsNoteLanguageKey() throws {
        let workDir = tempDir()
        try LanguageOverride(code: "ca").save(workDir: workDir, base: "x")
        let text = try String(contentsOf: LanguageOverride.url(workDir: workDir, base: "x"), encoding: .utf8)
        XCTAssertFalse(text.contains("note_language"), text)
    }

    func testNoteOnlySidecarRoundTripsAndLeavesSpokenLanguageAlone() throws {
        let workDir = tempDir()
        try LanguageOverride(noteLanguage: "fr").save(workDir: workDir, base: "n")
        let loaded = LanguageOverride.load(workDir: workDir, base: "n")
        XCTAssertEqual(loaded?.noteLanguage, "fr")
        XCTAssertEqual(loaded?.code, "")
        var config = TranscribeConfig()
        config.language = EmbeddedModelCatalog.automaticID
        let applied = LanguageOverride.applying(to: config, workDir: workDir, wavBase: "n")
        XCTAssertEqual(applied.language, EmbeddedModelCatalog.automaticID, "no spoken override in a note-only sidecar")
    }

    func testBothHalvesCoexistAndBadNoteLanguageIsDropped() throws {
        let workDir = tempDir()
        try LanguageOverride(code: "ca", noteLanguage: "en").save(workDir: workDir, base: "b")
        XCTAssertEqual(LanguageOverride.load(workDir: workDir, base: "b"),
                       LanguageOverride(code: "ca", noteLanguage: "en"))
        try LanguageOverride(code: "ca", noteLanguage: "klingon").save(workDir: workDir, base: "c")
        XCTAssertEqual(LanguageOverride.load(workDir: workDir, base: "c"), LanguageOverride(code: "ca"))
        try LanguageOverride(noteLanguage: "klingon").save(workDir: workDir, base: "d")
        XCTAssertNil(LanguageOverride.load(workDir: workDir, base: "d"))
    }

    func testApplyingResolvesAVariantsSourceBase() throws {
        let workDir = tempDir()
        try LanguageOverride(code: "ca").save(workDir: workDir, base: "meeting")
        var config = TranscribeConfig()
        config.language = EmbeddedModelCatalog.automaticID
        let applied = LanguageOverride.applying(to: config, workDir: workDir, wavBase: "meeting@large-v3-turbo-en")
        XCTAssertEqual(applied.language, "ca")
    }
}
