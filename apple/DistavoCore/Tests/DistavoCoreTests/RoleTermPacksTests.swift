import XCTest
@testable import DistavoCore

/// Role term packs (Vikunja #3950, 4 Nov comment): a participants line that names a role seeds the
/// spelling glossary with that field's terms. Synthetic participants only.
final class RoleTermPacksTests: XCTestCase {
    func testAccountantSeedsUKTaxTerms() {
        let hints = SpeakerHints(participants: "Sam (accountant for example-accounts.co.uk), Marc (me)")
        let terms = hints.roleTerms
        for t in ["VAT", "PAYE", "IR35", "FreeAgent", "Mettle", "Tide", "Qdos"] {
            XCTAssertTrue(terms.contains(t), "missing \(t)")
        }
    }

    func testNoRoleNoTerms() {
        XCTAssertEqual(SpeakerHints(participants: "Edward (Cambridge University), Marc (me)").roleTerms, [])
        XCTAssertEqual(SpeakerHints().roleTerms, [])
    }

    func testRoleMatchesWholeWordsOnly() {
        // "accountancy" is not "accountant"; "discount" must not trigger anything.
        XCTAssertEqual(SpeakerHints(participants: "Pat from Accountancy Weekly").roleTerms, [])
        XCTAssertEqual(SpeakerHints(participants: "Discount Desk").roleTerms, [])
    }

    func testRoleTermsAreCappedAndDeduplicated() {
        let hints = SpeakerHints(participants: "an accountant and a tax adviser")
        XCTAssertEqual(hints.roleTerms.count, Set(hints.roleTerms).count)
        XCTAssertLessThanOrEqual(hints.roleTerms.count, 30)
    }
}
