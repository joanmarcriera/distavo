import XCTest
@testable import DistavoCore

final class EngineRouterTests: XCTestCase {
    private let gb16: UInt64 = 16 << 30
    private let gb8: UInt64 = 8 << 30
    private func auto(_ preferred: String = "bsc-los") -> TranscribeConfig {
        TranscribeConfig(backend: "embedded", embeddedModel: "auto", language: "auto",
                         preferredCatalanModel: preferred)
    }
    private func d(_ code: String, _ p: Float = 0.9) -> LanguageDetection { .init(code: code, probability: p) }

    func testExplicitModelIsAlwaysHonoured() {
        let cfg = TranscribeConfig(backend: "embedded", embeddedModel: "small", language: "auto")
        let r = EngineRouter.choose(detections: [d("ca")], config: cfg, memoryBytes: gb16)
        XCTAssertEqual(r.model.id, "small")
        XCTAssertEqual(r.languageHint, "ca")
    }

    func testFixedLanguageWithAutoModelNeedsNoDetection() {
        let cfg = TranscribeConfig(backend: "embedded", embeddedModel: "auto", language: "de")
        XCTAssertFalse(EngineRouter.needsDetection(cfg))
        let r = EngineRouter.choose(detections: [], config: cfg, memoryBytes: gb16)
        XCTAssertEqual(r.model.id, "parakeet-tdt-v3")
        XCTAssertEqual(r.languageHint, "de")
    }

    func testCatalanOnlyUsesPreferredCatalanModel() {
        let r = EngineRouter.choose(detections: [d("ca"), d("ca"), d("ca")], config: auto("bsc-ca-3370h"), memoryBytes: gb16)
        XCTAssertEqual(r.model.id, "bsc-ca-3370h")
        XCTAssertEqual(r.languageHint, "ca")
    }

    func testCatalanSpanishMixUsesLanguagesOfSpain() {
        let r = EngineRouter.choose(detections: [d("ca"), d("es"), d("ca")], config: auto("bsc-ca-3370h"), memoryBytes: gb16)
        XCTAssertEqual(r.model.id, "bsc-los")
    }

    func testCatalanEnglishMixNeverGoesToParakeet() {
        for order in [[d("en"), d("ca"), d("en")], [d("ca"), d("en"), d("en")]] {
            let r = EngineRouter.choose(detections: order, config: auto(), memoryBytes: gb16)
            XCTAssertEqual(r.model.id, "bsc-los")
            XCTAssertEqual(r.languageHint, "ca")
        }
    }

    func testSpanishOnlyUsesLanguagesOfSpain() {
        XCTAssertEqual(EngineRouter.choose(detections: [d("es"), d("es")], config: auto(), memoryBytes: gb16).model.id, "bsc-los")
    }

    func testParakeetLanguagesUseParakeetWithDominantHint() {
        let r = EngineRouter.choose(detections: [d("en", 0.9), d("de", 0.7), d("en", 0.8)], config: auto(), memoryBytes: gb16)
        XCTAssertEqual(r.model.id, "parakeet-tdt-v3")
        XCTAssertEqual(r.languageHint, "en")
    }

    func testUnsupportedOrLowConfidenceFallsBackToWhisper() {
        XCTAssertEqual(EngineRouter.choose(detections: [d("ja")], config: auto(), memoryBytes: gb16).model.id, "large-v3-turbo")
        let low = EngineRouter.choose(detections: [d("ca", 0.3), d("en", 0.4)], config: auto(), memoryBytes: gb16)
        XCTAssertEqual(low.model.id, "large-v3-turbo")
        XCTAssertNil(low.languageHint)
        XCTAssertEqual(EngineRouter.choose(detections: [], config: auto(), memoryBytes: gb8).model.id, "small")
    }

    func testMemoryGateFallsBackWithNote() {
        let r = EngineRouter.choose(detections: [d("ca")], config: auto(), memoryBytes: gb8)
        XCTAssertEqual(r.model.id, "small")
        XCTAssertEqual(r.languageHint, "ca")
        XCTAssertNotNil(r.note)
    }

    /// Galician is in the Catalan family (rules 3–4): any confident Catalan/
    /// Galician/Basque mix routes to Languages of Spain, hinted with the
    /// actual detected code — here "gl", not "ca".
    func testGalicianEnglishMixUsesLanguagesOfSpainWithGalicianHint() {
        let r = EngineRouter.choose(detections: [d("gl"), d("en")], config: auto(), memoryBytes: gb16)
        XCTAssertEqual(r.model.id, "bsc-los")
        XCTAssertEqual(r.languageHint, "gl")
    }

    /// Basque-only still isn't the Catalan-only case (rule 3's `onlyCatalan`
    /// check is literally `set == ["ca"]`), so even with a preferred Catalan
    /// model configured, Basque-only routes to Languages of Spain hinted "eu".
    func testBasqueOnlyWithPreferredCatalanModelUsesLanguagesOfSpain() {
        let r = EngineRouter.choose(detections: [d("eu")], config: auto("bsc-ca-3370h"), memoryBytes: gb16)
        XCTAssertEqual(r.model.id, "bsc-los")
        XCTAssertEqual(r.languageHint, "eu")
    }

    /// Spanish+English is a Parakeet-covered pair (rule 5b): neither is
    /// Catalan-family, and both are in parakeetLanguages.
    func testSpanishEnglishMixUsesParakeet() {
        let r = EngineRouter.choose(detections: [d("es"), d("en")], config: auto(), memoryBytes: gb16)
        XCTAssertEqual(r.model.id, "parakeet-tdt-v3")
    }

    /// dominantCode ties break deterministically toward the alphabetically
    /// lower code (`a.key > b.key` in the `max` comparator means the *lower*
    /// key wins a tie, since `max` keeps the current best on `<`, not `>`).
    func testDominantCodeTieBreaksToAlphabeticallyLowerCode() {
        XCTAssertEqual(EngineRouter.dominantCode([d("fr", 0.6), d("de", 0.6)]), "de")
        XCTAssertEqual(EngineRouter.dominantCode([d("de", 0.6), d("fr", 0.6)]), "de")
    }

    // MARK: Language packs (Vikunja #2124)

    private func packs(_ ids: [String]) -> TranscribeConfig {
        TranscribeConfig(backend: "embedded", embeddedModel: "auto", language: "auto", languagePacks: ids)
    }

    func testDisabledPackLeavesRoutingUnchanged() {
        // Hebrew with no pack enabled: rule 6, exactly as before packs existed.
        let r = EngineRouter.choose(detections: [d("he")], config: auto(), memoryBytes: gb16)
        XCTAssertEqual(r.model.id, "large-v3-turbo")
        XCTAssertEqual(r.languageHint, "he")
    }

    func testEnabledPackRoutesItsLanguage() {
        let r = EngineRouter.choose(detections: [d("he"), d("he")], config: packs(["hebrew"]), memoryBytes: gb16)
        XCTAssertEqual(r.model.id, "ivrit-he")
        XCTAssertEqual(r.languageHint, "he")
        XCTAssertNil(r.note)
    }

    func testPackLanguageMixedWithEnglishNeverGoesToParakeet() {
        for order in [[d("en"), d("he"), d("en")], [d("he"), d("en"), d("en")]] {
            let r = EngineRouter.choose(detections: order, config: packs(["hebrew"]), memoryBytes: gb16)
            XCTAssertEqual(r.model.id, "ivrit-he")
            XCTAssertEqual(r.languageHint, "he")
        }
    }

    func testFixedLanguageUsesEnabledPack() {
        var cfg = packs(["hebrew"]); cfg.language = "he"
        XCTAssertFalse(EngineRouter.needsDetection(cfg))
        let r = EngineRouter.choose(detections: [], config: cfg, memoryBytes: gb8)
        XCTAssertEqual(r.model.id, "ivrit-he")   // turbo fine-tune: no memory floor
        XCTAssertEqual(r.languageHint, "he")
    }

    func testPackMemoryFloorFallsBackWithNote() {
        let r = EngineRouter.choose(detections: [d("th")], config: packs(["thai"]), memoryBytes: gb8)
        XCTAssertEqual(r.model.id, "small")           // large-v3 fine-tune: 16 GB floor
        XCTAssertEqual(r.languageHint, "th")
        XCTAssertNotNil(r.note)
    }

    func testCatalanStillBeatsAnEnabledPack() {
        let r = EngineRouter.choose(detections: [d("ca"), d("he")], config: packs(["hebrew"]), memoryBytes: gb16)
        XCTAssertEqual(r.model.id, "bsc-los")
    }

    func testUnknownPackIdIsIgnored() {
        let r = EngineRouter.choose(detections: [d("he")], config: packs(["no-such-pack"]), memoryBytes: gb16)
        XCTAssertEqual(r.model.id, "large-v3-turbo")
    }

    func testExplicitPackModelIsHonouredLikeAnyModel() {
        let cfg = TranscribeConfig(backend: "embedded", embeddedModel: "ivrit-he", language: "auto")
        XCTAssertEqual(EngineRouter.choose(detections: [d("en")], config: cfg, memoryBytes: gb16).model.id, "ivrit-he")
    }

    // MARK: Vikunja #2667 — detection with a pinned model

    private func pin(_ m: String, language: String = "auto") -> TranscribeConfig {
        TranscribeConfig(backend: "embedded", embeddedModel: m, language: language)
    }

    func testPinnedModelStillNeedsDetectionButFixedLanguageDoesNot() {
        XCTAssertTrue(EngineRouter.needsDetection(pin("large-v3-turbo")))
        XCTAssertFalse(EngineRouter.needsDetection(pin("small", language: "de")))
    }

    func testDeferOnDetectorOutageOnlyWhenModelIsAutomatic() {
        XCTAssertTrue(EngineRouter.deferOnDetectorOutage(auto()))
        XCTAssertFalse(EngineRouter.deferOnDetectorOutage(pin("large-v3-turbo")))
    }

    func testPinnedTurboUsesDetectedCatalanAndRecommendsBSC() {
        let r = EngineRouter.choose(detections: [d("ca", 0.92), d("ca", 0.90), d("en", 0.60)],
                                    config: pin("large-v3-turbo"), memoryBytes: gb16)
        XCTAssertEqual(r.model.id, "large-v3-turbo")
        XCTAssertEqual(r.languageHint, "ca")
        XCTAssertEqual(r.languageSource, .detected)
        XCTAssertEqual(r.confidence, 0.92)
        XCTAssertTrue(r.pinned)
        XCTAssertEqual(r.recommendation, "Catalan detected \u{2014} the BSC model is recommended.")
    }

    func testPinnedCatalanWinsOverDominantEnglish() {
        let r = EngineRouter.choose(detections: [d("en"), d("ca"), d("en")],
                                    config: pin("large-v3-turbo"), memoryBytes: gb16)
        XCTAssertEqual(r.languageHint, "ca")
    }

    func testPinnedBSCModelGetsNoRecommendation() {
        let r = EngineRouter.choose(detections: [d("ca")], config: pin("bsc-los"), memoryBytes: gb16)
        XCTAssertEqual(r.model.id, "bsc-los")
        XCTAssertNil(r.recommendation)
    }

    func testPinnedSmallWithGalicianRecommendsBSC() {
        let r = EngineRouter.choose(detections: [d("gl")], config: pin("small"), memoryBytes: gb16)
        XCTAssertEqual(r.languageHint, "gl")
        XCTAssertEqual(r.recommendation, "Galician detected \u{2014} the BSC model is recommended.")
    }

    func testPinnedParakeetKeepsModelAndWarnsWhenLanguageUncovered() {
        let r = EngineRouter.choose(detections: [d("ja")], config: pin("parakeet-tdt-v3"), memoryBytes: gb16)
        XCTAssertEqual(r.model.id, "parakeet-tdt-v3")
        XCTAssertEqual(r.recommendation,
            "Japanese detected \u{2014} \(r.model.displayName) does not cover it; Automatic is recommended.")
        XCTAssertTrue(r.recommendation!.contains("Fast (Parakeet, 25 languages)"))
        // Catalan takes precedence over the coverage message.
        let c = EngineRouter.choose(detections: [d("ca")], config: pin("parakeet-tdt-v3"), memoryBytes: gb16)
        XCTAssertEqual(c.recommendation, "Catalan detected \u{2014} the BSC model is recommended.")
    }

    func testPinnedWithNoConfidentDetectionLetsModelDetect() {
        for dets in [[d("ca", 0.3), d("en", 0.4)], []] {
            let r = EngineRouter.choose(detections: dets, config: pin("large-v3-turbo"), memoryBytes: gb16)
            XCTAssertNil(r.languageHint)
            XCTAssertEqual(r.languageSource, .modelDetects)
            XCTAssertNil(r.confidence)
            XCTAssertNil(r.recommendation)
        }
    }

    func testFixedLanguageSourceIsFixed() {
        let r = EngineRouter.choose(detections: [], config: pin("small", language: "de"), memoryBytes: gb16)
        XCTAssertEqual(r.languageSource, .fixed)
        XCTAssertEqual(r.languageHint, "de")
        XCTAssertNil(r.confidence)
    }

    func testLogLines() {
        let turbo = EngineRouter.choose(detections: [d("ca", 0.92)], config: pin("large-v3-turbo"), memoryBytes: gb16)
        XCTAssertEqual(turbo.logLine,
            "Using large-v3-turbo (pinned) \u{2014} language ca (detected, 92% confidence)")
        let bsc = EngineRouter.choose(detections: [d("ca", 0.92)], config: auto(), memoryBytes: gb16)
        XCTAssertEqual(bsc.logLine,
            "Using bsc-los (automatic) \u{2014} language ca (detected, 92% confidence)")
        let de = EngineRouter.choose(detections: [], config: TranscribeConfig(
            backend: "embedded", embeddedModel: "auto", language: "de"), memoryBytes: gb16)
        XCTAssertEqual(de.logLine,
            "Using parakeet-tdt-v3 (automatic) \u{2014} language de (set in Settings)")
        let none = EngineRouter.choose(detections: [], config: pin("large-v3-turbo"), memoryBytes: gb16)
        XCTAssertEqual(none.logLine,
            "Using large-v3-turbo (pinned) \u{2014} language not detected; the model detects it itself")
    }

    /// A single-language fine-tune must not be forced into a language it was not
    /// trained for: the hint drops so WhisperKit detects itself.
    func testPinnedSingleLanguageModelDropsUncoveredHint() {
        let w = EngineRouter.choose(detections: [d("en")], config: pin("techiaith-cy"), memoryBytes: gb16)
        XCTAssertEqual(w.model.id, "techiaith-cy")
        XCTAssertNil(w.languageHint)
        XCTAssertEqual(w.languageSource, .modelDetects)
        XCTAssertNil(w.confidence)
        XCTAssertNotNil(w.recommendation)
        let es = EngineRouter.choose(detections: [d("es")], config: pin("bsc-ca-3370h"), memoryBytes: gb16)
        XCTAssertNil(es.languageHint)
        XCTAssertEqual(es.languageSource, .modelDetects)
    }

    func testPinnedCatalanOnlyBSCModelStillAdvisesForGalician() {
        let r = EngineRouter.choose(detections: [d("gl")], config: pin("bsc-ca-3370h"), memoryBytes: gb16)
        XCTAssertNotNil(r.recommendation)
        XCTAssertNil(r.languageHint)
        let ok = EngineRouter.choose(detections: [d("ca")], config: pin("bsc-ca-3370h"), memoryBytes: gb16)
        XCTAssertEqual(ok.languageHint, "ca")
        XCTAssertNil(ok.recommendation)
    }

    func testWhisperLanguagePlan() {
        XCTAssertEqual(EngineRouter.whisperLanguagePlan(hint: nil), WhisperLanguagePlan(language: nil, detectLanguage: true))
        XCTAssertEqual(EngineRouter.whisperLanguagePlan(hint: ""), WhisperLanguagePlan(language: nil, detectLanguage: true))
        XCTAssertEqual(EngineRouter.whisperLanguagePlan(hint: "auto"), WhisperLanguagePlan(language: nil, detectLanguage: true))
        XCTAssertEqual(EngineRouter.whisperLanguagePlan(hint: "ca"), WhisperLanguagePlan(language: "ca", detectLanguage: false))
        // Invariant: WhisperKit must never be left with no language AND no detection
        // (it would silently prefill "en" and translate).
        for hint in WhisperLanguageCatalog.all.map(\.code) + [nil] {
            let plan = EngineRouter.whisperLanguagePlan(hint: hint)
            XCTAssertTrue(plan.language != nil || plan.detectLanguage, "hint \(hint ?? "nil")")
        }
    }
}
