import XCTest
@testable import DistavoCore

/// Vikunja #3950. Synthetic sentences only.
final class FuzzyVocabularyTests: XCTestCase {
    private func fix(_ terms: [String], _ text: String) -> String {
        Vocabulary.applyReplacements(text, rules: FuzzyVocabulary.rules(terms: terms, text: text))
    }

    func testNearMissesSnapToTheTerm() {
        XCTAssertEqual(fix(["Slurm"], "We run Slorm on the cluster and Slorm is fine."), "We run Slurm on the cluster and Slurm is fine.")
        XCTAssertEqual(fix(["InfiniBand"], "The infiniban fabric and the Infinivan switch."), "The InfiniBand fabric and the InfiniBand switch.")
        XCTAssertEqual(fix(["Nebius"], "We talked to Nebias yesterday."), "We talked to Nebius yesterday.")
        XCTAssertEqual(fix(["Lustre"], "A Lastre filesystem."), "A Lustre filesystem.")
    }

    func testMultiWordTermAcrossAdjacentWords() {
        XCTAssertEqual(fix(["Voltage Park"], "We met voltage parc last week."), "We met Voltage Park last week.")
    }

    func testLowercaseExactGetsTheTermCasing() {
        XCTAssertEqual(fix(["Slurm"], "we use slurm daily"), "we use Slurm daily")
    }

    func testShortTermsAndFarWordsAreLeftAlone() {
        XCTAssertEqual(fix(["Bull"], "The bill and the ball and Buell."), "The bill and the ball and Buell.")
        XCTAssertEqual(fix(["Claude"], "Everything in the cloud."), "Everything in the cloud.")
        XCTAssertEqual(fix(["Nvidia"], "Made in India."), "Made in India.")
    }

    func testDifferentFirstLetterIsLeftAlone() {
        XCTAssertEqual(fix(["Slurm"], "A blurm of words."), "A blurm of words.")
    }

    func testExactAndAlreadyCapitalisedAreUntouched() {
        XCTAssertTrue(FuzzyVocabulary.rules(terms: ["Slurm"], text: "Slurm and SLURM").isEmpty)
    }

    func testAnotherTermIsNeverRewrittenIntoThis() {
        // "Slurp" is its own term: not collapsed into Slurm.
        XCTAssertEqual(fix(["Slurm", "Slurp"], "Slurp is not Slurm."), "Slurp is not Slurm.")
    }

    func testPunctuationBreaksARun() {
        XCTAssertTrue(FuzzyVocabulary.rules(terms: ["Voltage Park"], text: "voltage, parc").isEmpty)
    }

    func testEmptyInputsAndRuleCap() {
        XCTAssertTrue(FuzzyVocabulary.rules(terms: [], text: "Slorm").isEmpty)
        XCTAssertTrue(FuzzyVocabulary.rules(terms: ["Slurm"], text: "").isEmpty)
        XCTAssertTrue(FuzzyVocabulary.rules(terms: ["", "  "], text: "Slorm").isEmpty)
    }

    func testConfigKeyIsOffByDefaultAndLenient() throws {
        XCTAssertFalse(TranscribeConfig().fuzzyVocabulary)
        let off = try JSONDecoder().decode(TranscribeConfig.self, from: Data("{}".utf8))
        XCTAssertFalse(off.fuzzyVocabulary)
        let on = try JSONDecoder().decode(TranscribeConfig.self, from: Data(#"{"fuzzy_vocabulary":true}"#.utf8))
        XCTAssertTrue(on.fuzzyVocabulary)
        let bad = try JSONDecoder().decode(TranscribeConfig.self, from: Data(#"{"fuzzy_vocabulary":"yes"}"#.utf8))
        XCTAssertFalse(bad.fuzzyVocabulary)
    }
}
