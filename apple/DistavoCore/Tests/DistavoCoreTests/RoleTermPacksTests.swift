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

    /// Review gap from drive 0054: a role phrase in the parentheses was kept whole as a "name" and so reached
    /// the fuzzy rewrite, which could snap ordinary words toward it. Only the organisation survives (parenthesised term first, as before).
    func testRolePhraseInParenthesesIsNotAParticipantTerm() {
        let phrase = SpeakerHints(participants: "Sam (accountant for Example Accounts Ltd), Marc (me)")
        XCTAssertEqual(phrase.participantTerms, ["Example Accounts Ltd", "Sam", "Marc"])
        let bare = SpeakerHints(participants: "Sam (accountant), Pat (bookkeeper for Acme Books)")
        XCTAssertEqual(bare.participantTerms, ["Sam", "Acme Books", "Pat"])
        // A plain company in parentheses is still a term.
        XCTAssertEqual(SpeakerHints(participants: "Bong Cha (Lightning AI) - interviewer").participantTerms,
                       ["Lightning AI", "Bong Cha"])
    }

    /// Review of the role-phrase fix: "for" inside an organisation name is kept, case does not matter.
    func testForInsideOrganisationNameAndCase() {
        XCTAssertEqual(SpeakerHints(participants: "Bong Cha (Centre for Computational Biology)").participantTerms,
                       ["Centre for Computational Biology", "Bong Cha"])
        XCTAssertEqual(SpeakerHints(participants: "Sam (Accountant For Acme Ltd)").participantTerms, ["Acme Ltd", "Sam"])
        XCTAssertEqual(SpeakerHints(participants: "Sam (CFO), Pat (the accountant)").participantTerms, ["Sam", "Pat"])
    }
}
