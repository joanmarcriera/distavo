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
                XCTAssertTrue(b.contains("Marc"), b)
            }
        }
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
