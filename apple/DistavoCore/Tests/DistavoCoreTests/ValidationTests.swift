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

    /// A realistically-shaped note: a title, a section heading, and well
    /// over `minWords` distinct words (no 5-gram repeats to trip collapse).
    private func fullLengthNote() -> String {
        "# Meeting notes\n\n## Executive summary\n" + (1...45).map { "point\($0)" }.joined(separator: " ")
    }

    func testValidateCleanSummaryPasses() {
        XCTAssertEqual(SummaryValidator.validate(fullLengthNote()), [])
    }

    /// The provenance footer (Pipeline appends it before validation) must not
    /// trip the repetition/overlong/empty checks on an otherwise clean note.
    func testValidateCleanSummaryWithFooterPasses() {
        let summary = fullLengthNote()
        let footer = NoteProvenance.footer(
            engine: "Languages of Spain (BSC)",
            detections: [(code: "ca", probability: 0.92), (code: "en", probability: 0.71)])
        XCTAssertEqual(SummaryValidator.validate(summary + footer), [])
    }

    // MARK: Truncated notes (Vikunja #2203)

    /// The live bug: a note that stopped mid-way through "## Speakers" — has
    /// a section heading, but far too few words to be a real note.
    func testValidateFlagsTruncatedNoteFromLiveBug() {
        let text = "# Meeting notes\n\n## Speakers\n* **Marat"
        let failures = SummaryValidator.validate(text)
        XCTAssertTrue(failures.contains("summary is truncated (4 words)"), "\(failures)")
    }

    /// Below `minWords` even with a heading present.
    func testValidateFlagsTruncatedByWordCount() {
        let text = "# Meeting notes\n\n## Executive summary\nA very short note."
        let failures = SummaryValidator.validate(text, minWords: 40)
        XCTAssertTrue(failures.contains { $0.hasPrefix("summary is truncated") })
    }

    /// Plenty of words, but never gets past the title into a real section.
    func testValidateFlagsTruncatedWhenNoSectionHeading() {
        let text = "# Meeting notes\n\n" + (1...45).map { "point\($0)" }.joined(separator: " ")
        let failures = SummaryValidator.validate(text)
        XCTAssertTrue(failures.contains { $0.hasPrefix("summary is truncated") })
    }

    /// Empty text keeps its own single message — never double-flagged.
    func testValidateEmptyIsNotAlsoFlaggedTruncated() {
        XCTAssertEqual(SummaryValidator.validate("   "), ["summary is empty"])
    }

    func testValidateFlagsTruncatedByWordCountRespectsCustomThreshold() {
        let text = "# Meeting notes\n\n## Executive summary\n" + (1...10).map { "point\($0)" }.joined(separator: " ")
        XCTAssertEqual(SummaryValidator.validate(text, minWords: 5), [])
        XCTAssertTrue(SummaryValidator.validate(text, minWords: 20)
            .contains { $0.hasPrefix("summary is truncated") })
    }
}
