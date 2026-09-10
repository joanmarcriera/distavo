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
}
