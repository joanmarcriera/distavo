import XCTest
@testable import DistavoCore

/// Pure-function tests for the local-model recipe from spike S0b
/// (Vikunja #2198 S3): loop guard, post-hoc cleanup, end-of-turn block.
final class SummaryGuardsTests: XCTestCase {

    // MARK: LoopGuard

    func testLongLineRepeatedFourTimesTrips() {
        let row = "- 600 per day | SPEAKER_01 | \"six hundred a day\" | day rate"
        let text = "# Meeting notes\n\n## Facts ledger\n" + Array(repeating: row, count: 4).joined(separator: "\n")
        XCTAssertTrue(LoopGuard.isLooping(text))
    }

    func testThreeRepeatsDoNotTrip() {
        let row = "- 600 per day | SPEAKER_01 | \"six hundred a day\" | day rate"
        XCTAssertFalse(LoopGuard.isLooping(Array(repeating: row, count: 3).joined(separator: "\n")))
    }

    func testShortRepeatedLinesAreExempt() {
        // Table separators and "none" bullets repeat legitimately.
        let text = Array(repeating: "|---|---|---|", count: 8).joined(separator: "\n")
            + "\n" + Array(repeating: "- none", count: 8).joined(separator: "\n")
        XCTAssertFalse(LoopGuard.isLooping(text))
    }

    func testRepeatedTailBlockTrips() {
        // No single line repeats 4 times, but the tail recurs inside the text before it.
        let unit = "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron pi rho sigma tau upsilon phi chi psi omega "
        let text = String(repeating: unit, count: 5)
        XCTAssertGreaterThan(text.count, 400)
        XCTAssertTrue(LoopGuard.isLooping(text))
    }

    func testOrdinaryNoteDoesNotTrip() {
        let text = (1...40).map { "## Section \($0)\nSome distinct content about topic number \($0) in the meeting." }
            .joined(separator: "\n\n")
        XCTAssertFalse(LoopGuard.isLooping(text))
    }

    func testRetryRunsHotter() {
        XCTAssertEqual(LoopGuard.retryTemperature(after: 0.3), 0.5, accuracy: 1e-9)
        XCTAssertEqual(LoopGuard.checkEveryTokens, 40)
    }

    // MARK: Headings

    func testRequiredHeadingCounts() {
        XCTAssertEqual(SummaryPostProcess.requiredHeadings(for: .factsFirst).count, 18)
        XCTAssertEqual(SummaryPostProcess.requiredHeadings(for: .classic).count, 16)
        XCTAssertFalse(SummaryPostProcess.requiredHeadings(for: .factsFirst).contains { $0.hasPrefix("## Step") })
        XCTAssertTrue(SummaryPostProcess.requiredHeadings(for: .classic).contains("## Action items"))
    }

    private func note(without skipped: Set<String> = [], style: Prompt.Style = .factsFirst) -> String {
        let body = SummaryPostProcess.requiredHeadings(for: style)
            .filter { !skipped.contains($0) }
            .map { "\($0)\n\nbody text\n" }
            .joined(separator: "\n")
        return "# Meeting notes\n\n" + body
    }

    func testMissingHeadingsDetected() {
        let text = note(without: ["## Action items"])
        XCTAssertEqual(SummaryPostProcess.missingHeadings(in: text, style: .factsFirst), ["## Action items"])
        XCTAssertTrue(SummaryPostProcess.missingHeadings(in: note(), style: .factsFirst).isEmpty)
    }

    func testHeadingMatchIsCaseAndDecorationTolerant() {
        let text = note().replacingOccurrences(of: "## Action items", with: "## **Action Items:**")
        XCTAssertTrue(SummaryPostProcess.missingHeadings(in: text, style: .factsFirst).isEmpty)
    }

    func testEnsureHeadingsInsertsAtCanonicalPosition() {
        let fixed = SummaryPostProcess.ensureHeadings(note(without: ["## Action items"]), style: .factsFirst)
        XCTAssertTrue(SummaryPostProcess.missingHeadings(in: fixed, style: .factsFirst).isEmpty)
        let order = fixed.components(separatedBy: "\n").filter { $0.hasPrefix("## ") }
        XCTAssertEqual(order, SummaryPostProcess.requiredHeadings(for: .factsFirst))
    }

    func testEnsureHeadingsRepairsTrailingAndMultipleGaps() {
        let missing: Set<String> = ["## Action items", "## Suggested follow-up email", "## Timeline"]
        let fixed = SummaryPostProcess.ensureHeadings(note(without: missing), style: .factsFirst)
        let order = fixed.components(separatedBy: "\n").filter { $0.hasPrefix("## ") }
        XCTAssertEqual(order, SummaryPostProcess.requiredHeadings(for: .factsFirst))
    }

    func testEnsureHeadingsLeavesCompleteNoteAlone() {
        let text = note()
        XCTAssertEqual(SummaryPostProcess.ensureHeadings(text, style: .factsFirst), text)
    }

    // MARK: Ledger dedupe

    func testDedupeRemovesRepeatedLedgerRowsOnly() {
        let text = """
        # Meeting notes

        ## Facts ledger
        - 600 a day | SPEAKER_01 | "six hundred a day" | day rate
        - outside IR35 | SPEAKER_01 | "outside IR35" | status
        - 600 a day | SPEAKER_01 | "six hundred a day." | day rate
        - 600 A DAY | SPEAKER_01 | "Six hundred a day" | rate

        ## Executive summary
        - 600 a day | SPEAKER_01 | "six hundred a day" | day rate
        """
        let out = SummaryPostProcess.dedupeLedgerRows(text)
        XCTAssertEqual(out.components(separatedBy: "600 a day").count - 1, 2,
                       "one ledger row survives, the unrelated section is untouched")
        XCTAssertTrue(out.contains("outside IR35"))
        XCTAssertTrue(out.contains("## Executive summary"))
    }

    func testDedupeKeepsDistinctFactsSharingAnExcerpt() {
        let text = """
        ## Facts ledger
        - day rate 600 | SPEAKER_01 | "six hundred a day outside IR35" | rate
        - IR35 outside | SPEAKER_01 | "six hundred a day outside IR35" | status
        """
        XCTAssertEqual(SummaryPostProcess.dedupeLedgerRows(text), text)
    }

    func testDedupeCapsRows() {
        let rows = (1...10).map { "- fact \($0) | A | \"quote \($0)\" | i" }.joined(separator: "\n")
        let out = SummaryPostProcess.dedupeLedgerRows("## Facts ledger\n" + rows, maxRows: 4)
        XCTAssertEqual(out.components(separatedBy: "\n").filter { $0.hasPrefix("- ") }.count, 4)
    }

    func testDedupeWithoutLedgerIsIdentity() {
        XCTAssertEqual(SummaryPostProcess.dedupeLedgerRows("# Meeting notes\n\n## Context\nx"),
                       "# Meeting notes\n\n## Context\nx")
    }

    // MARK: Trailing meta

    func testStripsTrailingSelfCorrectionAndNote() {
        let text = "# Meeting notes\n\n## Suggested follow-up email\nHi,\n\nThanks.\n\n"
            + "(Self-Correction: I misread the rate.)\n\n---\n\nNote: this summary was generated."
        XCTAssertEqual(SummaryPostProcess.stripTrailingMeta(text),
                       "# Meeting notes\n\n## Suggested follow-up email\nHi,\n\nThanks.")
    }

    func testStripsLoneRuleAndOfferToHelp() {
        let text = "## Suggested follow-up email\nHi,\n\n---\n\nLet me know if you want changes."
        XCTAssertEqual(SummaryPostProcess.stripTrailingMeta(text), "## Suggested follow-up email\nHi,")
    }

    /// An email whose last line is a sign-off must survive (review finding).
    func testKeepsEmailEndingLetMeKnow() {
        let text = "## Suggested follow-up email\nHi,\n\nThanks for the call.\n\nLet me know if I've missed anything."
        XCTAssertEqual(SummaryPostProcess.stripTrailingMeta(text), text)
    }

    /// Inside the follow-up email, an unseparated "Note:" paragraph is content.
    func testKeepsTrailingNoteParagraphInsideEmailButStripsItAfterRule() {
        let email = "## Suggested follow-up email\nHi,\n\nThanks.\n\nNote: I am away Friday."
        XCTAssertEqual(SummaryPostProcess.stripTrailingMeta(email), email)
        XCTAssertEqual(SummaryPostProcess.stripTrailingMeta(email + "\n\n---\n\nNote: generated."), email)
    }

    /// Outside the email section a trailing "Note:" paragraph is meta.
    func testStripsTrailingNoteAfterNonEmailSection() {
        let text = "## Suggested follow-up email\nHi,\n\n## Risks and concerns\nSome risk.\n\nNote: generated."
        XCTAssertEqual(SummaryPostProcess.stripTrailingMeta(text),
                       "## Suggested follow-up email\nHi,\n\n## Risks and concerns\nSome risk.")
    }

    func testBoldAndColonOnlyHeadingsCountAsPresent() {
        let bold = note().replacingOccurrences(of: "## Action items", with: "**Action items**")
        let colon = note().replacingOccurrences(of: "## Action items", with: "Action items:")
        for text in [bold, colon] {
            XCTAssertTrue(SummaryPostProcess.missingHeadings(in: text, style: .factsFirst).isEmpty)
            XCTAssertEqual(SummaryPostProcess.ensureHeadings(text, style: .factsFirst), text,
                           "no duplicate 'none stated' section")
        }
    }

    func testPipeTableLedgerRowsDoNotCollapsePerSpeaker() {
        let text = """
        ## Facts ledger
        | rate 600 | SPEAKER_01 | "six hundred a day" | rate |
        | start March | SPEAKER_01 | "from March" | date |
        | rate 600 | SPEAKER_01 | "six hundred a day" | rate |
        """
        let out = SummaryPostProcess.dedupeLedgerRows(text)
        XCTAssertTrue(out.contains("start March"))
        XCTAssertEqual(out.components(separatedBy: "\n").filter { $0.hasPrefix("|") }.count, 2)
    }

    func testKeepsNoteInsideTheBody() {
        let text = "## Risks and concerns\nNote: the rate is unconfirmed.\n\n## Suggested follow-up email\nHi,\n\nThanks."
        XCTAssertEqual(SummaryPostProcess.stripTrailingMeta(text), text)
    }

    func testCleanRunsAllStepsInOrder() {
        let broken = note(without: ["## Action items"]) + "\n\n---\n\nNote: done."
        let cleaned = SummaryPostProcess.clean(broken, style: .factsFirst)
        XCTAssertFalse(cleaned.contains("Note: done."))
        XCTAssertTrue(SummaryPostProcess.missingHeadings(in: cleaned, style: .factsFirst).isEmpty)
    }

    // MARK: End-of-turn block

    func testCatalanBlockIsInCatalanAndCarriesTheRecipe() {
        let b = EndOfTurnBlock.build(noteLanguage: "ca", style: .factsFirst,
                                     noteOwner: "Marc", ownerSpeaker: "SPEAKER_00")
        XCTAssertTrue(b.contains("CATALÀ"))
        XCTAssertTrue(b.contains("exactament els 18 encapçalaments"))
        XCTAssertTrue(b.contains("## Action items"))
        XCTAssertTrue(b.contains("màxim 25 files"))
        XCTAssertTrue(b.contains("SPEAKER_00 ÉS Marc"))
        XCTAssertTrue(b.contains("NOMÉS noms que apareixen literalment"))
        XCTAssertTrue(b.contains("No escriguis res després de l'última secció"))
    }

    func testEnglishBlockHasRoleAnchorAndLedgerCapForFactsFirst() {
        let b = EndOfTurnBlock.build(noteLanguage: nil, style: .factsFirst,
                                     noteOwner: "Ana", ownerSpeaker: "SPEAKER_01")
        XCTAssertTrue(b.contains("exactly the 18 section headings"))
        XCTAssertTrue(b.contains("max 25 unique rows"))
        XCTAssertTrue(b.contains("SPEAKER_01 IS Ana"))
        XCTAssertTrue(b.contains("ONLY names that appear literally"))
        XCTAssertTrue(b.contains("Output nothing after the last section"))
    }

    func testSpanishBlock() {
        let b = EndOfTurnBlock.build(noteLanguage: "es", style: .factsFirst,
                                     noteOwner: "Marc", ownerSpeaker: "SPEAKER_00")
        XCTAssertTrue(b.contains("ESPAÑOL"))
        XCTAssertTrue(b.contains("los 18 encabezados"))
    }

    func testClassicBlockHasNoLedgerRuleAndCountsSixteen() {
        let b = EndOfTurnBlock.build(noteLanguage: "en", style: .classic,
                                     noteOwner: "Marc", ownerSpeaker: "SPEAKER_00")
        XCTAssertTrue(b.contains("exactly the 16 section headings"))
        XCTAssertFalse(b.contains("ledger"))
    }

    func testBlockNeverContainsAFewShotExample() {
        // The spike rejected few-shot: the model copies the example.
        for lang in ["ca", "es", "en"] {
            let b = EndOfTurnBlock.build(noteLanguage: lang, style: .factsFirst,
                                         noteOwner: "Marc", ownerSpeaker: "SPEAKER_00")
            XCTAssertFalse(b.contains("Núria"))
            XCTAssertFalse(b.contains("# Meeting notes"))
        }
    }
}
