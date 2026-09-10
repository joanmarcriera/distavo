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
}
