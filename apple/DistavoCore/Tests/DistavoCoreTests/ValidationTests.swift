import XCTest
@testable import DistavoCore

final class ValidationTests: XCTestCase {

    func testWordsFromLowercasesAndTokenises() {
        XCTAssertEqual(SummaryValidator.words(from: "Hello, WORLD's test-case!"),
                       ["hello", "world's", "test-case"])
    }

    func testMostRepeatedNgram() {
        let words = SummaryValidator.words(from: "a b c a b c a b c")
        let (gram, count) = SummaryValidator.mostRepeatedNgram(words, size: 3)
        XCTAssertEqual(gram, "a b c")
        XCTAssertEqual(count, 3)
    }

    func testValidateFlagsEmpty() {
        XCTAssertEqual(SummaryValidator.validate("   "), ["summary is empty"])
    }

    func testValidateFlagsOverlong() {
        let failures = SummaryValidator.validate(String(repeating: "a", count: 11), maxChars: 10)
        XCTAssertTrue(failures.contains { $0.contains("unusually long") })
    }

    func testValidateFlagsRepetitionCollapse() {
        let text = String(repeating: "the cat sat on mat ", count: 20)
        let failures = SummaryValidator.validate(text)
        XCTAssertTrue(failures.contains { $0.contains("repetition collapse") })
    }

    func testValidateCleanSummaryPasses() {
        XCTAssertEqual(SummaryValidator.validate("This is a perfectly normal short summary."), [])
    }

    /// The provenance footer (Pipeline appends it before validation) must not
    /// trip the repetition/overlong/empty checks on an otherwise clean note.
    func testValidateCleanSummaryWithFooterPasses() {
        let summary = "This is a perfectly normal short summary."
        let footer = NoteProvenance.footer(
            engine: "Languages of Spain (BSC)",
            detections: [(code: "ca", probability: 0.92), (code: "en", probability: 0.71)])
        XCTAssertEqual(SummaryValidator.validate(summary + footer), [])
    }
}
