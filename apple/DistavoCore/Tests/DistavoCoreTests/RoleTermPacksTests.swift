import XCTest
@testable import DistavoCore

/// Role term packs (Vikunja #3950, 4 Nov comment): a participants line that names a role seeds the
/// spelling glossary with that field's terms. Synthetic participants only.
final class RoleTermPacksTests: XCTestCase {
    func testAccountantSeedsUKTaxTerms() {
        let hints = SpeakerHints(participants: "Sam (accountant for example-accounts.co.uk), Marc (me)")
        let terms = hints.roleTerms
        for t in ["VAT", "PAYE", "IR35", "FreeAgent", "Qdos"] {
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

    func testCapAndDedupeAcrossPacks() {
        let a = RoleTermPack(id: "a", triggers: ["alpha"], terms: (1...20).map { "Aterm\($0)" })
        let b = RoleTermPack(id: "b", triggers: ["alpha"], terms: ["aterm1", "Bterm"])
        let terms = RoleTermPacks.terms(forParticipants: "alpha", packs: [a, b])
        XCTAssertEqual(terms.count, RoleTermPacks.maxTerms)
        XCTAssertEqual(terms.filter { $0.lowercased() == "aterm1" }.count, 1)
    }

    func testMatchingIsCaseAndPunctuationTolerant() {
        XCTAssertFalse(SpeakerHints(participants: "Sam (ACCOUNTANT), Marc").roleTerms.isEmpty)
        XCTAssertFalse(SpeakerHints(participants: "Sam, bookkeeper; Marc").roleTerms.isEmpty)
    }

    func testBrandNamesThatAreCommonWordsAreNotSeeded() {
        let terms = SpeakerHints(participants: "Sam (accountant)").roleTerms.map { $0.lowercased() }
        for w in ["tide", "starling", "mettle"] { XCTAssertFalse(terms.contains(w)) }
    }
}
