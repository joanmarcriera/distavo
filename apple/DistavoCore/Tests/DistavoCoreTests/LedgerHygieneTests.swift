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
