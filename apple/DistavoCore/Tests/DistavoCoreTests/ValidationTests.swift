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

    // MARK: - Unicode-aware tokenisation (Vikunja #2670)

    /// Accented letters, apostrophes, the Catalan middle dot and ñ stay inside one word.
    func testWordsKeepAccentedCatalanAndSpanishWordsWhole() {
        XCTAssertEqual(SummaryValidator.words(from: "La reunió"), ["la", "reunió"])
        XCTAssertEqual(SummaryValidator.words(from: "l'acord d'aquesta"),
                       ["l'acord", "d'aquesta"])
        XCTAssertEqual(SummaryValidator.words(from: "d\u{2019}aquesta"), ["d\u{2019}aquesta"])
        XCTAssertEqual(SummaryValidator.words(from: "col·laborar"), ["col·laborar"])
        XCTAssertEqual(SummaryValidator.words(from: "El año España"), ["el", "año", "españa"])
    }

    /// The truncation check counts real words: 30 accented words + 3 title/heading words (33) are too thin
    /// for minWords 40. Uses mid-word accents ("línia"), which the ASCII regex split in two.
    func testValidateTruncationCountsAccentedWordsOnce() {
        let text = "# Meeting notes\n\n## Resum\n" + Array(repeating: "línia", count: 30).joined(separator: " ")
        XCTAssertTrue(SummaryValidator.validate(text)
            .contains { $0.hasPrefix("summary is truncated (33 words)") })
    }

    /// Combining marks stay inside the word (Tamil, Thai, Hindi, NFD Catalan) — review of #2670.
    func testWordsKeepCombiningMarksWhole() {
        XCTAssertEqual(SummaryValidator.words(from: "தமிழ் கூட்டத்தில்").count, 2)
        XCTAssertEqual(SummaryValidator.words(from: "การประชุมวันนี้").count, 1)
        XCTAssertEqual(SummaryValidator.words(from: "bai\u{0308}xa li\u{0301}nia").count, 2)
    }

    /// A legitimately long accented Catalan note is not flagged.
    func testValidateLongAccentedCatalanNotePasses() {
        let sentences = [
            "Durant la reunió es va parlar de l'acord amb el proveïdor.",
            "L'equip va decidir col·laborar amb d'altres departaments aquesta setmana.",
            "També es va revisar el pressupost d'aquesta línia i el calendari del projecte.",
            "El responsable presentarà les conclusions a la propera sessió de coordinació.",
            "Mañana el año próximo España necesitará más soporte técnico.",
        ]
        let text = "# Meeting notes\n\n## Resum\n" + sentences.joined(separator: "\n")
        XCTAssertGreaterThanOrEqual(SummaryValidator.words(from: text).count, 40)
        XCTAssertEqual(SummaryValidator.validate(text), [])
    }

    /// A genuine repetition collapse in accented Catalan is still caught.
    func testValidateFlagsRepetitionCollapseInCatalan() {
        let text = "# Meeting notes\n\n## Resum\n"
            + Array(repeating: "la reunió de la reunió de", count: 30).joined(separator: " ")
        XCTAssertTrue(SummaryValidator.validate(text)
            .contains { $0.hasPrefix("possible repetition collapse") })
    }
}
