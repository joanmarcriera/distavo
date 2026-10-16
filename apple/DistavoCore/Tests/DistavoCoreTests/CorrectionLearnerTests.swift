import XCTest
@testable import DistavoCore

final class CorrectionLearnerTests: XCTestCase {
    func testASingleMisheardWordBecomesARule() {
        let r = CorrectionLearner.suggestions(
            original: ["Hem parlat de l'ERP i dels becups."],
            edited: ["Hem parlat de l'ERP i dels backups."])
        XCTAssertEqual(r, [ReplacementRule(from: "becups", to: "backups")])
    }

    func testAPhraseSwapAndAcronymCaseFix() {
        let r = CorrectionLearner.suggestions(
            original: ["Fem servir Entre id amb el firewall d'erp."],
            edited: ["Fem servir Entra ID amb el firewall d'ERP."])
        XCTAssertTrue(r.contains(ReplacementRule(from: "Entre id", to: "Entra ID")))
        XCTAssertTrue(r.contains(ReplacementRule(from: "d'erp", to: "d'ERP")))
    }

    func testPunctuationAndPlainCapitalOnlyChangesAreIgnored() {
        XCTAssertTrue(CorrectionLearner.suggestions(
            original: ["hola, què tal"], edited: ["Hola. Què tal?"]).isEmpty)
    }

    func testLongRewritesAndNumbersAreNotLearned() {
        XCTAssertTrue(CorrectionLearner.suggestions(
            original: ["costa 200 euros"], edited: ["costa 300 euros"]).isEmpty)
        XCTAssertTrue(CorrectionLearner.suggestions(
            original: ["una dues tres quatre cinc"], edited: ["a b c d e f g"]).isEmpty)
    }

    func testDuplicatesAreCollapsedAndExistingRulesFiltered() {
        let r = CorrectionLearner.suggestions(
            original: ["becups ahir", "i becups avui"], edited: ["backups ahir", "i backups avui"])
        XCTAssertEqual(r.count, 1)
        XCTAssertTrue(CorrectionLearner.newRules(r, existing: [ReplacementRule(from: "BECUPS", to: "x")]).isEmpty)
    }

    func testVocabularyTermsKeepNamesAndSkipExisting() {
        let rules = [ReplacementRule(from: "sonic world", to: "SonicWall"),
                     ReplacementRule(from: "becups", to: "backups")]
        XCTAssertEqual(CorrectionLearner.vocabularyTerms(for: rules, existing: ["sonicwall"]), [])
        XCTAssertEqual(CorrectionLearner.vocabularyTerms(for: rules, existing: []), ["SonicWall"])
    }
}
