import XCTest
@testable import DistavoCore

/// #3857 (reviewer note of drive n): when the owner's speaker label is unknown the end-of-prompt
/// SPEAKER ROLES block must not say "unknown IS <owner>".
final class UnknownOwnerRolesTests: XCTestCase {

    private func block(_ lang: String?, _ owner: String, template: SummaryTemplate? = nil) -> String {
        EndOfTurnBlock.build(noteLanguage: lang, style: .factsFirst, noteOwner: "Marc", ownerSpeaker: owner,
                             template: template)
    }

    func testUnknownLabelNeverReadsAsAnAssertion() {
        for lang in [nil, "en", "ca", "es", "fr"] as [String?] {
            for owner in ["unknown", "Unknown", "", "  "] {
                let b = block(lang, owner)
                XCTAssertFalse(b.lowercased().contains("unknown is"), "\(lang ?? "nil"): \(b)")
                XCTAssertFalse(b.lowercased().contains("unknown és"), b)
                XCTAssertFalse(b.lowercased().contains("unknown es "), b)
            }
        }
    }

    /// The templated end block (`EndOfTurnBlock.templated`) goes through the same roles text (review of o).
    func testTemplatedBlockWithUnknownLabelAsksForEvidence() {
        let template = SummaryTemplate.parse(
            id: "pin", name: "Pin", summary: "s", outline: "## One\nDo one.\n\n## Two\nDo two.\n")!
        for lang in [nil, "ca", "es"] as [String?] {
            let b = block(lang, "unknown", template: template)
            XCTAssertFalse(b.lowercased().contains("unknown is"), b)
            XCTAssertFalse(b.lowercased().contains("unknown és"), b)
            XCTAssertFalse(b.lowercased().contains("unknown es "), b)
        }
        XCTAssertTrue(block(nil, "unknown", template: template).contains("is not known"))
    }

    /// Three or more voices: the English unknown wording must not say "either speaker" (review of o).
    func testEnglishUnknownCoversAnySpeaker() {
        let b = block(nil, "unknown")
        XCTAssertFalse(b.contains("either speaker"), b)
        XCTAssertTrue(b.contains("any speaker's statements"), b)
    }

    /// A label with a trailing newline that names a real turn label still resolves (review of o).
    func testOwnerLabelWithTrailingNewlineResolves() {
        let transcript = "[SPEAKER_00]\nhello\n\n[SPEAKER_01]\nhi\n"
        XCTAssertEqual(OwnerSpeakerLabel.effective(configured: "SPEAKER_00\n", transcript: transcript), "SPEAKER_00")
    }

    func testEnglishUnknownAsksForEvidence() {
        let b = block(nil, "unknown")
        XCTAssertTrue(b.contains("SPEAKER ROLES"), b)
        XCTAssertTrue(b.contains("not known"), b)
        XCTAssertTrue(b.contains("evidence"), b)
    }

    func testCatalanAndSpanishUnknownUseTheirOwnLanguage() {
        XCTAssertTrue(block("ca", "unknown").contains("no es coneix"))
        XCTAssertTrue(block("es", "unknown").contains("no se conoce"))
        XCTAssertTrue(block("en", "\n").contains("is not known"))
    }

    func testKnownLabelKeepsTheAuthoritativeSentence() {
        for lang in [nil, "ca", "es", "fr"] as [String?] {
            let b = block(lang, "SPEAKER_00")
            XCTAssertTrue(b.contains("SPEAKER_00 "), b)
            XCTAssertFalse(b.contains("is not known"), b)
        }
        XCTAssertTrue(block(nil, "SPEAKER_00").contains("SPEAKER ROLES (authoritative): SPEAKER_00 IS Marc"))
    }
}
