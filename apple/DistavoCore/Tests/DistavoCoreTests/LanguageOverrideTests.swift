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
}
