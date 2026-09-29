import XCTest
@testable import DistavoCore

final class NoteProvenanceTests: XCTestCase {

    func testNoDetectionsOmitsSentence() {
        let footer = NoteProvenance.footer(engine: "Languages of Spain (BSC)", detections: [])
        XCTAssertEqual(footer, "\n\n---\n_Transcribed on this Mac with Languages of Spain (BSC)._")
    }

    func testOneDetection() {
        let footer = NoteProvenance.footer(
            engine: "Languages of Spain (BSC)", detections: [(code: "ca", probability: 0.92)])
        XCTAssertEqual(
            footer,
            "\n\n---\n_Transcribed on this Mac with Languages of Spain (BSC). Detected language: Catalan 92%._")
    }

    func testTwoDetections() {
        let footer = NoteProvenance.footer(
            engine: "Languages of Spain (BSC)",
            detections: [(code: "ca", probability: 0.92), (code: "en", probability: 0.71)])
        XCTAssertEqual(
            footer,
            "\n\n---\n_Transcribed on this Mac with Languages of Spain (BSC). Detected language: Catalan 92%, English 71%._")
    }

    /// A code the catalog doesn't recognise falls back to the raw code rather
    /// than crashing or dropping the detection.
    func testUnknownCodeFallsBackToCode() {
        let footer = NoteProvenance.footer(
            engine: "Fast (Parakeet, 25 languages)", detections: [(code: "zzq", probability: 0.5)])
        XCTAssertEqual(
            footer,
            "\n\n---\n_Transcribed on this Mac with Fast (Parakeet, 25 languages). Detected language: zzq 50%._")
    }

    /// Probabilities round to the nearest whole percent, away from zero at .5.
    func testProbabilityRounding() {
        let footer = NoteProvenance.footer(
            engine: "Best (Whisper large-v3 turbo)",
            detections: [(code: "en", probability: 0.925), (code: "de", probability: 0.004)])
        XCTAssertTrue(footer.contains("English 93%"), footer)
        XCTAssertTrue(footer.contains("German 0%"), footer)
    }

    /// The detector runs on up to three windows, so a single-language meeting
    /// yields one repeated code. The footer must collapse that to one entry,
    /// at its highest observed probability.
    func testRepeatedCodeAcrossWindowsCollapsesToOneEntryAtItsHighestProbability() {
        let footer = NoteProvenance.footer(
            engine: "Fast (Parakeet, 25 languages)",
            detections: [(code: "en", probability: 0.91), (code: "en", probability: 0.89), (code: "en", probability: 0.93)])
        XCTAssertEqual(
            footer,
            "\n\n---\n_Transcribed on this Mac with Fast (Parakeet, 25 languages). Detected language: English 93%._")
    }

    /// Mixed windows: dedupe per code (keeping the max), then order by that
    /// max probability descending.
    func testMixedWindowsDedupeAndOrderByHighestProbabilityDescending() {
        let footer = NoteProvenance.footer(
            engine: "Languages of Spain (BSC)",
            detections: [(code: "ca", probability: 0.85), (code: "en", probability: 0.7), (code: "ca", probability: 0.95)])
        XCTAssertEqual(
            footer,
            "\n\n---\n_Transcribed on this Mac with Languages of Spain (BSC). Detected language: Catalan 95%, English 70%._")
    }

    func testLanguageUsedAndRecommendation() {
        let footer = NoteProvenance.footer(
            engine: "Best (Whisper large-v3 turbo)", detections: [(code: "ca", probability: 0.92)],
            languageUsed: "Catalan (detected, 92% confidence)",
            recommendation: "Catalan detected \u{2014} the BSC model is recommended.")
        XCTAssertEqual(footer,
            "\n\n---\n_Transcribed on this Mac with Best (Whisper large-v3 turbo). Detected language: Catalan 92%. Language used: Catalan (detected, 92% confidence). Catalan detected \u{2014} the BSC model is recommended._")
    }

    func testLanguageUsedDescriptions() {
        let cfg = { (m: String, l: String) in TranscribeConfig(backend: "embedded", embeddedModel: m, language: l) }
        let mem: UInt64 = 16 << 30
        let det = EngineRouter.choose(detections: [LanguageDetection(code: "ca", probability: 0.92)],
                                      config: cfg("large-v3-turbo", "auto"), memoryBytes: mem)
        XCTAssertEqual(NoteProvenance.languageUsed(det), "Catalan (detected, 92% confidence)")
        let fixed = EngineRouter.choose(detections: [], config: cfg("small", "de"), memoryBytes: mem)
        XCTAssertEqual(NoteProvenance.languageUsed(fixed), "German (set in Settings)")
        let model = EngineRouter.choose(detections: [], config: cfg("small", "auto"), memoryBytes: mem)
        XCTAssertEqual(NoteProvenance.languageUsed(model), "detected by the model")
    }
}
