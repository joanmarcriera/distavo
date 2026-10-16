import XCTest
@testable import DistavoCore

/// Vikunja #3584: the automatic offer to clear unheard vocabulary terms when participants or the
/// language change. Synthetic placeholder names only.
final class VocabularyClearOfferTests: XCTestCase {
    private var dir: URL!
    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vco-\(UUID().uuidString)")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private let terms = ["TermA", "TermB", "TermC"]
    private let alpha = "The note owner (me): host. Other participants: Alpha (lead), Bravo"
    private let charlie = "Other participants: Charlie, Delta"

    func testFirstMeetingNeverOffers() {
        XCTAssertNil(VocabularyClearOffer.observe(language: "en", participants: alpha, terms: terms,
                                                  transcript: "talk of terma", workDir: dir))
        XCTAssertNil(VocabularyClearOffer.pending(workDir: dir, currentTerms: terms))
    }

    func testSamePeopleAndLanguageNoOffer() {
        VocabularyClearOffer.observe(language: "en", participants: alpha, terms: terms, transcript: "", workDir: dir)
        // One shared first name is enough to count as the same group.
        XCTAssertNil(VocabularyClearOffer.observe(language: "en", participants: "Other participants: Bravo, Echo",
                                                  terms: terms, transcript: "", workDir: dir))
    }

    func testDifferentPeopleOffersOnlyUnheardTerms() throws {
        VocabularyClearOffer.observe(language: "en", participants: alpha, terms: terms, transcript: "", workDir: dir)
        let offer = try XCTUnwrap(VocabularyClearOffer.observe(language: "en", participants: charlie, terms: terms,
                                                               transcript: "we discussed terma today", workDir: dir))
        XCTAssertEqual(offer.reason, .participants)
        XCTAssertEqual(offer.terms, ["TermB", "TermC"])
        let pending = try XCTUnwrap(VocabularyClearOffer.pending(workDir: dir, currentTerms: terms))
        XCTAssertEqual(VocabularyClearOffer.applying(pending, to: terms), ["TermA"])
    }

    func testLanguageChangeOffers() throws {
        VocabularyClearOffer.observe(language: "ca", participants: nil, terms: terms, transcript: "", workDir: dir)
        let offer = try XCTUnwrap(VocabularyClearOffer.observe(language: "en", participants: nil, terms: terms,
                                                               transcript: "", workDir: dir))
        XCTAssertEqual(offer.reason, .language)
        XCTAssertEqual(offer.terms.count, 3)
    }

    func testMissingInfoDoesNotLookLikeAChange() {
        VocabularyClearOffer.observe(language: "ca", participants: alpha, terms: terms, transcript: "", workDir: dir)
        // No language detected and nobody listed: nothing to compare, nothing offered, context kept.
        XCTAssertNil(VocabularyClearOffer.observe(language: nil, participants: nil, terms: terms, transcript: "", workDir: dir))
        XCTAssertNil(VocabularyClearOffer.observe(language: "ca", participants: alpha, terms: terms, transcript: "", workDir: dir))
    }

    func testNothingToClearAndDismiss() throws {
        VocabularyClearOffer.observe(language: "ca", participants: nil, terms: terms, transcript: "", workDir: dir)
        XCTAssertNil(VocabularyClearOffer.observe(language: "en", participants: nil, terms: terms,
                                                  transcript: "terma termb termc", workDir: dir), "every term was heard")
        let offer = VocabularyClearOffer.observe(language: "ca", participants: nil, terms: terms, transcript: "", workDir: dir)
        XCTAssertNotNil(offer)
        VocabularyClearOffer.dismiss(workDir: dir)
        XCTAssertNil(VocabularyClearOffer.pending(workDir: dir, currentTerms: terms))
    }

    func testPendingDropsTermsAlreadyRemoved() throws {
        VocabularyClearOffer.observe(language: "ca", participants: nil, terms: terms, transcript: "", workDir: dir)
        VocabularyClearOffer.observe(language: "en", participants: nil, terms: terms, transcript: "", workDir: dir)
        XCTAssertEqual(VocabularyClearOffer.pending(workDir: dir, currentTerms: ["TermB"])?.terms, ["TermB"])
        XCTAssertNil(VocabularyClearOffer.pending(workDir: dir, currentTerms: ["Other"]))
    }

    func testListedNames() {
        XCTAssertEqual(SpeakerHints.listedNames(alpha), ["alpha", "bravo"])
        XCTAssertEqual(SpeakerHints.listedNames("Other participants: the CEO of a firm, Echo"), ["echo"])
        XCTAssertEqual(SpeakerHints.listedNames(nil), [])
    }
}
