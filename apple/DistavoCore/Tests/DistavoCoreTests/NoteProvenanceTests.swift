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
}
