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

    /// A config written before `when_done`/`open_when_done` existed (Vikunja
    /// #2199, #2205) decodes to `[]`, so nothing opens or re-runs automatically
    /// until the user opts in.
    func testPreWhenDoneConfigStaysEmpty() throws {
        let cfg = try decode(#"{"transcribe": {"backend": "embedded", "embedded_model": "auto"}}"#)
        XCTAssertEqual(cfg.whenDone, [])
    }

    func testLanguagePacksRoundTripAndDropUnknownIds() throws {
        let cfg = try decode(#"{"transcribe": {"language_packs": ["thai", "bogus", "hebrew"]}}"#)
        XCTAssertEqual(cfg.transcribe.languagePacks, ["thai", "bogus", "hebrew"])
        XCTAssertEqual(cfg.transcribe.enabledLanguagePacks.map(\.id), ["hebrew", "thai"])   // catalog order
        let data = try JSONEncoder().encode(cfg)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains(#""language_packs":["thai","bogus","hebrew"]"#), json)
    }

    // MARK: Note language (Vikunja #2147) — same migration rule as `transcribe.backend`.

    /// A config predating `summarise.note_language` decodes to "en": no
    /// existing user's notes silently change language.
    func testPreNoteLanguageConfigStaysEnglish() throws {
        let cfg = try decode(#"{"summarise": {"backend": "server"}}"#)
        XCTAssertEqual(cfg.summarise.noteLanguage, "en")
    }

    /// An empty config (no summarise key at all) also stays "en".
    func testEmptyConfigNoteLanguageStaysEnglish() throws {
        let cfg = try decode("{}")
        XCTAssertEqual(cfg.summarise.noteLanguage, "en")
    }

    /// An explicit value round-trips as-is.
    func testExplicitNoteLanguageIsKeptVerbatim() throws {
        let cfg = try decode(#"{"summarise": {"note_language": "auto"}}"#)
        XCTAssertEqual(cfg.summarise.noteLanguage, "auto")
    }

    /// A fixed target language (Vikunja #2956) is just another string value:
    /// kept verbatim, and `auto`/`en`/missing keep their meaning.
    func testFixedTargetNoteLanguageIsKeptAndLegacyValuesUnchanged() throws {
        XCTAssertEqual(try decode(#"{"summarise": {"note_language": "fr"}}"#).summarise.noteLanguage, "fr")
        XCTAssertEqual(try decode(#"{"summarise": {"note_language": "en"}}"#).summarise.noteLanguage, "en")
        XCTAssertEqual(try decode(#"{"summarise": {"note_language": "auto"}}"#).summarise.noteLanguage, "auto")
        // An unknown value survives decoding and resolves like "en".
        let odd = try decode(#"{"summarise": {"note_language": "klingon"}}"#)
        XCTAssertEqual(odd.summarise.noteLanguage, "klingon")
        XCTAssertNil(NoteLanguage.resolve(setting: odd.summarise.noteLanguage, perRecording: nil, detected: "fr"))
        // Round-trips through encode.
        let data = try JSONEncoder().encode(try decode(#"{"summarise": {"note_language": "fr"}}"#))
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(#""note_language":"fr""#))
    }

    /// Only a fresh install (no config file yet) gets "auto".
    func testFreshInstallGetsAutoNoteLanguage() {
        let cfg = Config.recommendedForThisMac(embeddedSupported: true, memoryBytes: 16 << 30)
        XCTAssertEqual(cfg.summarise.noteLanguage, "auto")
        let intel = Config.recommendedForThisMac(embeddedSupported: false, memoryBytes: 16 << 30)
        XCTAssertEqual(intel.summarise.noteLanguage, "auto")
    }

    // MARK: Silence auto-stop (Vikunja #2665)

    func testOldConfigHasSilenceOptionsOffWithPrefilledMinutes() throws {
        let cfg = try decode(#"{"transcribe": {"backend": "server"}}"#)
        XCTAssertFalse(cfg.suggestStopOnSilence)
        XCTAssertFalse(cfg.autoStopOnSilence)
        XCTAssertEqual(cfg.suggestStopSilenceMinutes, 2)
        XCTAssertEqual(cfg.autoStopSilenceMinutes, 5)
    }

    func testSilenceOptionsRoundTrip() throws {
        var cfg = Config()
        cfg.suggestStopOnSilence = true; cfg.suggestStopSilenceMinutes = 7
        cfg.autoStopOnSilence = true; cfg.autoStopSilenceMinutes = 12
        let again = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(cfg))
        XCTAssertEqual(again, cfg)
        XCTAssertTrue(again.suggestStopOnSilence)
        XCTAssertEqual(again.autoStopSilenceMinutes, 12)
    }

    func testSilenceMinutesClampTo1Through60() throws {
        let cfg = try decode(#"{"suggest_stop_silence_minutes": 0, "auto_stop_silence_minutes": 999}"#)
        XCTAssertEqual(cfg.suggestStopSilenceMinutes, 1)
        XCTAssertEqual(cfg.autoStopSilenceMinutes, 60)
        let neg = try decode(#"{"suggest_stop_silence_minutes": -3}"#)
        XCTAssertEqual(neg.suggestStopSilenceMinutes, 1)
    }

    func testWrongTypedSilenceKeyFallsBackAndRestDecodes() throws {
        let cfg = try decode(#"{"auto_stop_silence_minutes": "5", "auto_stop_on_silence": "yes", "note_owner": "Ana"}"#)
        XCTAssertEqual(cfg.autoStopSilenceMinutes, 5)
        XCTAssertFalse(cfg.autoStopOnSilence)
        XCTAssertEqual(cfg.noteOwner, "Ana")
    }

    // MARK: summarise.embedded_model (Vikunja #2198 S1)

    /// A config predating the key must keep Apple's model: nothing may route to
    /// Gemma until the user picks it.
    func testMissingEmbeddedSummaryModelDecodesToApple() throws {
        let cfg = try decode(#"{"summarise": {"backend": "embedded", "embedded_enabled": true}}"#)
        XCTAssertEqual(cfg.summarise.embeddedModel, "apple")
        XCTAssertEqual(try decode("{}").summarise.embeddedModel, "apple")
    }

    func testEmbeddedSummaryModelRoundTrips() throws {
        let cfg = try decode(#"{"summarise": {"embedded_model": "gemma-4-e4b"}}"#)
        XCTAssertEqual(cfg.summarise.embeddedModel, "gemma-4-e4b")
        let again = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(cfg))
        XCTAssertEqual(again.summarise.embeddedModel, "gemma-4-e4b")
    }

    func testRecommendedForThisMacKeepsAppleSummaryModel() {
        let cfg = Config.recommendedForThisMac(embeddedSupported: true, memoryBytes: 64 << 30)
        XCTAssertEqual(cfg.summarise.embeddedModel, "apple")
        XCTAssertFalse(cfg.summarise.embeddedEnabled)
    }

    func testFreshInstallLeavesSilenceOptionsOff() {
        let cfg = Config.recommendedForThisMac(embeddedSupported: true, memoryBytes: 16 << 30)
        XCTAssertFalse(cfg.suggestStopOnSilence)
        XCTAssertFalse(cfg.autoStopOnSilence)
    }
}
