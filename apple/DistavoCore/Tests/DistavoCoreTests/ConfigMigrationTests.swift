import XCTest
@testable import DistavoCore

/// Golden configs from every era must decode AND dispatch exactly as before
/// 1.11 (spec §5.1 / Codex finding 7). Only a missing file gets "auto".
final class ConfigMigrationTests: XCTestCase {
    private func decode(_ json: String) throws -> Config {
        try JSONDecoder().decode(Config.self, from: json.data(using: .utf8)!)
    }

    func testPreEmbeddedServerConfigStaysServer() throws {
        let cfg = try decode(#"{"transcribe": {"whisperx_url": "http://10.0.0.5:9000", "model": "medium", "language": "en"}}"#)
        XCTAssertEqual(cfg.transcribe.backend, "server")
        XCTAssertEqual(cfg.transcribe.embeddedModel, "large-v3-turbo")
        XCTAssertEqual(cfg.transcribe.language, "en")
        XCTAssertEqual(cfg.transcribe.preferredCatalanModel, "bsc-los")
    }

    func testCurrent16GBEmbeddedConfigKeepsExplicitModelAndLanguage() throws {
        let cfg = try decode(#"{"transcribe": {"backend": "embedded", "embedded_model": "large-v3-turbo", "language": "es"}}"#)
        XCTAssertEqual(cfg.transcribe.embeddedModel, "large-v3-turbo")
        XCTAssertEqual(cfg.transcribe.language, "es")
        XCTAssertFalse(EmbeddedModelCatalog.isAutomatic(cfg.transcribe.embeddedModel))
    }

    func testCurrent8GBEmbeddedConfigKeepsSmall() throws {
        let cfg = try decode(#"{"transcribe": {"backend": "embedded", "embedded_model": "small"}}"#)
        XCTAssertEqual(cfg.transcribe.embeddedModel, "small")
        XCTAssertEqual(cfg.transcribe.language, "en")
    }

    func testEmptyAndUnknownValuesAreKeptVerbatim() throws {
        let cfg = try decode(#"{"transcribe": {"backend": "embedded", "embedded_model": "no-such", "language": ""}}"#)
        XCTAssertEqual(cfg.transcribe.embeddedModel, "no-such")   // stored as-is …
        XCTAssertEqual(EmbeddedModelCatalog.model(id: cfg.transcribe.embeddedModel).id, "large-v3-turbo") // … resolves as before
        XCTAssertEqual(cfg.transcribe.language, "")
    }

    func testInvalidPreferredCatalanModelFallsBackToLoS() throws {
        let cfg = try decode(#"{"transcribe": {"preferred_catalan_model": "bogus"}}"#)
        XCTAssertEqual(cfg.transcribe.effectivePreferredCatalanModel, "bsc-los")
        let ok = try decode(#"{"transcribe": {"preferred_catalan_model": "bsc-ca-3370h"}}"#)
        XCTAssertEqual(ok.transcribe.effectivePreferredCatalanModel, "bsc-ca-3370h")
    }

    func testFreshInstallOnAppleSiliconIsAutomatic() {
        let cfg = Config.recommendedForThisMac(embeddedSupported: true, memoryBytes: 16 << 30)
        XCTAssertEqual(cfg.transcribe.backend, "embedded")
        XCTAssertEqual(cfg.transcribe.embeddedModel, "auto")
        XCTAssertEqual(cfg.transcribe.language, "auto")
    }

    func testFreshInstallOnIntelStaysServerAndEnglish() {
        let cfg = Config.recommendedForThisMac(embeddedSupported: false, memoryBytes: 16 << 30)
        XCTAssertEqual(cfg.transcribe.backend, "server")
        XCTAssertEqual(cfg.transcribe.language, "en")
    }

    func testSaveReloadDoesNotIntroduceAuto() throws {
        let cfg = try decode(#"{"transcribe": {"backend": "embedded", "embedded_model": "small", "language": "en"}}"#)
        let data = try JSONEncoder().encode(cfg)
        let again = try JSONDecoder().decode(Config.self, from: data)
        XCTAssertEqual(again.transcribe.embeddedModel, "small")
        XCTAssertEqual(again.transcribe.language, "en")
    }

    /// A config written before language packs existed decodes to no packs, so
    /// automatic routing is byte-for-byte what it was (Vikunja #2124).
    func testPreLanguagePackConfigHasNoPacksEnabled() throws {
        let cfg = try decode(#"{"transcribe": {"backend": "embedded", "embedded_model": "auto"}}"#)
        XCTAssertEqual(cfg.transcribe.languagePacks, [])
        XCTAssertTrue(cfg.transcribe.enabledLanguagePacks.isEmpty)
        XCTAssertTrue(Config.recommendedForThisMac(embeddedSupported: true).transcribe.languagePacks.isEmpty)
    }

    /// A config written before `open_when_done` existed (Vikunja #2199) decodes
    /// to `.off`, so nothing opens automatically until the user opts in.
    func testPreOpenWhenDoneConfigStaysOff() throws {
        let cfg = try decode(#"{"transcribe": {"backend": "embedded", "embedded_model": "auto"}}"#)
        XCTAssertEqual(cfg.openWhenDone, .off)
    }

    func testLanguagePacksRoundTripAndDropUnknownIds() throws {
        let cfg = try decode(#"{"transcribe": {"language_packs": ["thai", "bogus", "hebrew"]}}"#)
        XCTAssertEqual(cfg.transcribe.languagePacks, ["thai", "bogus", "hebrew"])
        XCTAssertEqual(cfg.transcribe.enabledLanguagePacks.map(\.id), ["hebrew", "thai"])   // catalog order
        let data = try JSONEncoder().encode(cfg)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains(#""language_packs":["thai","bogus","hebrew"]"#), json)
    }
}
