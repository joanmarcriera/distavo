import XCTest
@testable import DistavoCore

/// "Languages I speak" (`transcribe.spoken_languages`, D085, task 4016): detections outside the user's
/// short list are dropped before routing. An extension of `EngineRouterTests` so
/// `swift test --filter EngineRouterTests` runs these too.
extension EngineRouterTests {
    private var mem16: UInt64 { 16 << 30 }
    private func cfg(_ spoken: [String], model: String = "auto", language: String = "auto") -> TranscribeConfig {
        var c = TranscribeConfig(backend: "embedded", embeddedModel: model, language: language)
        c.spokenLanguages = spoken
        return c
    }
    private func det(_ code: String, _ p: Float, scores: [String: Float] = [:]) -> LanguageDetection {
        LanguageDetection(code: code, probability: p, scores: scores)
    }

    func testSpokenEmptyListIsTodaysResult() {
        let cases: [[LanguageDetection]] = [
            [], [det("nn", 0.43), det("en", 0.40)], [det("ca", 0.9), det("en", 0.8)],
            [det("es", 0.9)], [det("fi", 0.7), det("de", 0.6), det("fi", 0.8)],
        ]
        for detections in cases {
            let before = EngineRouter.choose(detections: detections,
                                             config: TranscribeConfig(backend: "embedded", embeddedModel: "auto", language: "auto"),
                                             memoryBytes: mem16)
            let after = EngineRouter.choose(detections: detections, config: cfg([]), memoryBytes: mem16)
            XCTAssertEqual(before, after, "\(detections)")
            XCTAssertNil(after.restrictionNote)
        }
    }

    func testSpokenDropsAStrayNynorskDetection() {
        let r = EngineRouter.choose(detections: [det("nn", 0.43), det("en", 0.40)],
                                    config: cfg(["en", "ca", "es"]), memoryBytes: mem16)
        XCTAssertEqual(r.languageHint, "en")
        XCTAssertEqual(r.model.id, "parakeet-tdt-v3")
        XCTAssertEqual(r.languageSource, .detected)
        XCTAssertEqual(r.restrictionNote, "detected nn 43%, not in your languages, using en")
    }

    func testSpokenAllOutsideUsesTheFirstListedLanguage() {
        let r = EngineRouter.choose(detections: [det("fi", 0.7), det("nn", 0.6)],
                                    config: cfg(["en", "ca", "es"]), memoryBytes: mem16)
        XCTAssertEqual(r.languageHint, "en")
        XCTAssertEqual(r.restrictionNote, "detected fi 70%, nn 60%, not in your languages, using en")
    }

    func testSpokenAllOutsideUsesTheBestAllowedRawScore() {
        let r = EngineRouter.choose(
            detections: [det("fi", 0.7, scores: ["fi": 0.7, "es": 0.2, "en": 0.05]),
                         det("nn", 0.6, scores: ["nn": 0.6, "en": 0.1, "es": 0.15])],
            config: cfg(["en", "ca", "es"]), memoryBytes: mem16)
        XCTAssertEqual(r.languageHint, "es")
        XCTAssertEqual(r.model.id, "bsc-los")
    }

    func testSpokenFixedLanguageStillWins() {
        let r = EngineRouter.choose(detections: [det("ca", 0.9)],
                                    config: cfg(["en", "ca"], language: "de"), memoryBytes: mem16)
        XCTAssertEqual(r.languageHint, "de")
        XCTAssertEqual(r.languageSource, .fixed)
        XCTAssertNil(r.restrictionNote)
    }

    func testSpokenPinnedModelKeepsItsOwnRule() {
        // A pinned model is honoured; the hint is the restricted one.
        let r = EngineRouter.choose(detections: [det("nn", 0.8), det("en", 0.6)],
                                    config: cfg(["en", "ca", "es"], model: "small"), memoryBytes: mem16)
        XCTAssertEqual(r.model.id, "small")
        XCTAssertTrue(r.pinned)
        XCTAssertEqual(r.languageHint, "en")
        XCTAssertNotNil(r.restrictionNote)
    }

    func testSpokenCatalanStillSelectsTheCatalanModel() {
        let r = EngineRouter.choose(detections: [det("ca", 0.9), det("ca", 0.8), det("nn", 0.55)],
                                    config: cfg(["en", "ca", "es"]), memoryBytes: mem16)
        XCTAssertEqual(r.languageHint, "ca")
        XCTAssertTrue(r.model.id.hasPrefix("bsc-"))
    }

    func testSpokenNoDropNoNote() {
        let r = EngineRouter.choose(detections: [det("en", 0.9), det("en", 0.8)],
                                    config: cfg(["en", "ca", "es"]), memoryBytes: mem16)
        XCTAssertEqual(r.languageHint, "en")
        XCTAssertNil(r.restrictionNote)
    }

    func testSpokenListIsNormalised() {
        XCTAssertEqual(EngineRouter.normalisedSpokenLanguages([" EN", "ca", "", "en", "Es "]), ["en", "ca", "es"])
    }

    func testSpokenLanguagesDecode() throws {
        let old = try JSONDecoder().decode(TranscribeConfig.self, from: Data(#"{"language":"auto"}"#.utf8))
        XCTAssertEqual(old.spokenLanguages, [])
        let set = try JSONDecoder().decode(TranscribeConfig.self, from: Data(#"{"spoken_languages":["en","ca"]}"#.utf8))
        XCTAssertEqual(set.spokenLanguages, ["en", "ca"])
        let again = try JSONDecoder().decode(TranscribeConfig.self, from: JSONEncoder().encode(set))
        XCTAssertEqual(again.spokenLanguages, ["en", "ca"])
        let wrongType = try JSONDecoder().decode(TranscribeConfig.self, from: Data(#"{"spoken_languages":"en"}"#.utf8))
        XCTAssertEqual(wrongType.spokenLanguages, [])
    }
}
