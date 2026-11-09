import XCTest
@testable import DistavoCore

/// Vikunja #4017: figures must be in the quote, the speaker comes from the turn holding the quote,
/// trivia and "unclear" rows are dropped, and the ledger is capped. Synthetic text only.
final class LedgerHygieneTests: XCTestCase {

    private let transcript = """
    [SPEAKER_00]
    So how many accelerators are in the new cluster, roughly thirty five and forty thousand depending on the quarter.

    [SPEAKER_01]
    We are planning thirty thousand accelerators for the first phase and the budget is two hundred and fifty thousand pounds.

    [SPEAKER_00]
    The meeting starts at seven in the morning and we use Teams for all the calls with the vendor team.

    [SPEAKER_01]
    Most of our storage work is break-fix, sixty to seventy percent of it, and the rest is projects.
    """

    private func ledger(_ rows: [String]) -> String {
        "# Meeting notes\n\n## Facts ledger\n" + rows.joined(separator: "\n") + "\n\n## Summary\nText.\n"
    }

    func testFigureMustBeInTheQuote() {
        let r = LedgerVerifier.verify(ledger([
            "- 30,000 accelerators | SPEAKER_00 | \"thirty five and forty thousand depending on the quarter\" | count",
            "- 30,000 accelerators | SPEAKER_01 | \"planning thirty thousand accelerators for the first phase\" | count",
        ]), transcript: transcript)
        XCTAssertEqual(r.removed, 1)
        XCTAssertEqual(r.text.components(separatedBy: "\n").filter { $0.hasPrefix("- 30,000") }.count, 1)
        XCTAssertTrue(r.text.contains("SPEAKER_01"))
    }

    func testInterpretedFigureIsFlaggedNotRemoved() {
        let r = LedgerVerifier.verify(ledger([
            "- 250 pounds | SPEAKER_01 | \"the budget is two hundred and fifty thousand pounds\" | (interpreted) 250,000 pounds",
        ]), transcript: transcript)
        XCTAssertEqual(r.removed, 0)
        XCTAssertEqual(r.flagged, 1)
    }

    func testSpokenFigureMatchesDigits() {
        let r = LedgerVerifier.verify(ledger([
            "- £250,000 budget | SPEAKER_01 | \"the budget is two hundred and fifty thousand pounds\" | budget",
            "- 60-70% break-fix | SPEAKER_01 | \"break-fix, sixty to seventy percent of it\" | share",
        ]), transcript: transcript)
        XCTAssertEqual(r.removed, 0)
        XCTAssertEqual(r.flagged, 0, r.text)
        XCTAssertEqual(r.dropped, 0)
    }

    func testSpeakerComesFromTheTurnHoldingTheQuote() {
        let r = LedgerVerifier.verify(ledger([
            "- 30,000 accelerators | SPEAKER_00 | \"planning thirty thousand accelerators for the first phase\" | count",
            "| Storage break-fix 60-70% | SPEAKER_00 | \"sixty to seventy percent of it\" | share |",
        ]), transcript: transcript)
        XCTAssertEqual(r.corrected, 2)
        XCTAssertTrue(r.text.contains("- 30,000 accelerators | SPEAKER_01 |"))
        XCTAssertTrue(r.text.contains("| Storage break-fix 60-70% | SPEAKER_01 | \"sixty to seventy percent of it\" | share |"))
    }

    func testSpeakerNamesNotInTheTranscriptAreLeftAlone() {
        let r = LedgerVerifier.verify(ledger([
            "- 30,000 accelerators | Marc | \"planning thirty thousand accelerators for the first phase\" | count",
        ]), transcript: transcript)
        XCTAssertEqual(r.corrected, 0)
        XCTAssertTrue(r.text.contains("| Marc |"))
    }

    // Real names (#4017, the 4 Nov "60,000 under Marc and under Ahmed" case): the transcript has labels only,
    // the model wrote names. The name->label map is learned from the rows whose quote has one clear holder.
    private let advice = """
    [SPEAKER_00]
    I have put about forty thousand pounds into the pension so far this year and I would like to know more.

    [SPEAKER_01]
    The annual allowance for pension contributions is sixty thousand pounds for most people, and the carry forward rules help.

    [SPEAKER_00]
    My salary is ninety five thousand pounds before tax and the bonus comes in March every single year.

    [SPEAKER_01]
    You can carry forward unused allowance from the last three tax years if you were a member of a scheme.
    """

    func testRealNameSpeakerIsCorrectedFromLearnedMapping() {
        let r = LedgerVerifier.verify(ledger([
            "- £40,000 into the pension | Marc | \"about forty thousand pounds into the pension so far this year\" | paid in",
            "- £95,000 salary | Marc | \"My salary is ninety five thousand pounds before tax\" | salary",
            "- £60,000 allowance | Ahmed | \"annual allowance for pension contributions is sixty thousand pounds\" | limit",
            "- £60,000 allowance limit | Marc | \"allowance for pension contributions is sixty thousand pounds for most people\" | limit",
            "- carry forward 3 years | Ahmed | \"carry forward unused allowance from the last three tax years\" | rule",
        ]), transcript: advice)
        XCTAssertEqual(r.corrected, 1, r.text)
        XCTAssertTrue(r.text.contains("- £60,000 allowance limit | Ahmed |"), r.text)
        XCTAssertTrue(r.text.contains("- £95,000 salary | Marc |"))
    }

    func testRealNameWithoutEnoughEvidenceIsLeftAlone() {
        let r = LedgerVerifier.verify(ledger([
            "- £60,000 allowance limit | Marc | \"allowance for pension contributions is sixty thousand pounds for most people\" | limit",
        ]), transcript: advice)
        XCTAssertEqual(r.corrected, 0)
        XCTAssertTrue(r.text.contains("| Marc |"))
    }

    func testTwoNamesOnOneLabelAreAmbiguousAndLeftAlone() {
        let r = LedgerVerifier.verify(ledger([
            "- £40,000 | Marc | \"about forty thousand pounds into the pension so far this year\" | a",
            "- £95,000 | Marc | \"My salary is ninety five thousand pounds before tax\" | b",
            "- £40,000 again | Mark | \"about forty thousand pounds into the pension so far this year\" | c",
            "- £95,000 again | Mark | \"My salary is ninety five thousand pounds before tax\" | d",
            "- £60,000 | Marc | \"allowance for pension contributions is sixty thousand pounds for most people\" | e",
        ]), transcript: advice)
        XCTAssertEqual(r.corrected, 0, r.text)
    }

    func testFirstNameMatchesRenamedLabel() {
        let t = advice.replacingOccurrences(of: "SPEAKER_00", with: "Marc Riera")
            .replacingOccurrences(of: "SPEAKER_01", with: "Ahmed Khan")
        let r = LedgerVerifier.verify(ledger([
            "- £60,000 allowance limit | Marc | \"allowance for pension contributions is sixty thousand pounds for most people\" | limit",
        ]), transcript: t)
        XCTAssertEqual(r.corrected, 1, r.text)
        XCTAssertTrue(r.text.contains("| Ahmed Khan |"), r.text)
    }

    func testTriviaIsDropped() {
        let q = "\"we use Teams for all the calls with the vendor team\""
        let r = LedgerVerifier.verify(ledger([
            "- Teams | SPEAKER_00 | \(q) | tool",
            "- AI | SPEAKER_00 | \(q) | topic",
            "- 7 a.m. | SPEAKER_00 | \"starts at seven in the morning\" | time",
            "- 11 years old | SPEAKER_01 | \"the rest is projects\" | age",
            "- Vendor | SPEAKER_00 | \(q) | unclear",
            "- Vendor | SPEAKER_00 | \(q) | none",
            "- 30,000 accelerators | SPEAKER_01 | \"planning thirty thousand accelerators\" | count",
        ]), transcript: transcript)
        XCTAssertEqual(r.dropped, 6)
        XCTAssertEqual(r.removed, 0)
        XCTAssertEqual(r.text.components(separatedBy: "\n").filter { $0.hasPrefix("- ") }.count, 1)
    }

    func testRowCap() {
        let rows = (1...20).map { _ in
            "- 30,000 accelerators | SPEAKER_01 | \"planning thirty thousand accelerators\" | count"
        }
        let r = LedgerVerifier.verify(ledger(rows), transcript: transcript)
        XCTAssertEqual(r.text.components(separatedBy: "\n").filter { $0.hasPrefix("- 30,000") }.count, LedgerVerifier.maxRows)
        XCTAssertEqual(r.dropped, 5)
    }

    func testFiguresHelperFoldsSeparators() {
        XCTAssertEqual(LedgerVerifier.figures(in: "£2,300 and 30,000 GPUs, 2.5 TB"), ["2300", "30000", "2.5"])
        XCTAssertEqual(LedgerVerifier.figures(in: "no numbers"), [])
    }

    func testNotesMentionDroppedAndCorrected() {
        let n = LedgerVerifier.notes(for: .init(text: "", removed: 0, flagged: 0, dropped: 2, corrected: 1))
        XCTAssertEqual(n.count, 2)
    }
}
