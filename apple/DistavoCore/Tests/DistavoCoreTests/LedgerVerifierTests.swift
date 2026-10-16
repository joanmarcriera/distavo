import XCTest
@testable import DistavoCore

/// Vikunja #3581: ledger rows the transcript does not support are removed or flagged.
/// The fixture mirrors the 2026-10-16 field test in shape (invented IR35/Slurm/Bull/dates next to
/// real tool names) with made-up wording, so no private meeting text is committed.
final class LedgerVerifierTests: XCTestCase {

    private let transcript = """
    [SPEAKER_00]
    Bon dia, avui parlem del projecte de la nova oficina i de com dibuixem els diagrames.

    [SPEAKER_01]
    Nosaltres fem servir Visio per als diagrames de xarxa, però l'equip de disseny prefereix Lucidchart.

    [SPEAKER_00]
    El pressupost és de dos mil tres cents euros i el termini és a finals de mes, sense falta.

    [SPEAKER_01]
    Crec que la reunió amb l'Èlia serà dimarts que ve a les deu, a la sala gran del segon pis.
    """

    private func ledger(_ rows: [String]) -> String {
        "# Meeting notes\n\n## Facts ledger\n" + rows.joined(separator: "\n") + "\n\n## Executive summary\nText.\n"
    }

    func testSupportedRowsSurviveAndInventedOnesAreRemoved() {
        let note = ledger([
            "- Visio | SPEAKER_01 | \"fem servir Visio per als diagrames de xarxa\" | diagram tool",
            "- Lucidchart | SPEAKER_01 | \"l'equip de disseny prefereix Lucidchart\" | design team tool",
            "- IR35 | SPEAKER_01 | \"outside IR35 for the whole contract\" | status",
            "- Slurm | SPEAKER_00 | \"the Slurm cluster was moved last week\" | HPC scheduler",
            "- 16 September | SPEAKER_00 | \"the sixteenth of September\" | date",
        ])
        let r = LedgerVerifier.verify(note, transcript: transcript)
        XCTAssertEqual(r.removed, 3)
        XCTAssertEqual(r.flagged, 0)
        XCTAssertTrue(r.text.contains("- Visio |"))
        XCTAssertTrue(r.text.contains("- Lucidchart |"))
        for gone in ["IR35", "Slurm", "16 September"] { XCTAssertFalse(r.text.contains(gone), gone) }
        XCTAssertTrue(r.text.contains("## Executive summary\nText."), "other sections are untouched")
    }

    func testRealQuoteThatDoesNotContainTheFactIsFlaggedNotRemoved() {
        let note = ledger([
            "- Bull | SPEAKER_01 | \"el termini és a finals de mes, sense falta\" | vendor",
            "- deadline end of month | SPEAKER_00 | \"el termini és a finals de mes\" | deadline",
        ])
        let r = LedgerVerifier.verify(note, transcript: transcript)
        XCTAssertEqual(r.removed, 0)
        XCTAssertEqual(r.flagged, 1)
        XCTAssertTrue(r.text.contains("- Bull | SPEAKER_01 | \"el termini és a finals de mes, sense falta\" | vendor [unverified]"))
        // A lower-case fact in the note's language is not checked against the quote's language.
        XCTAssertFalse(r.text.contains("deadline [unverified]"))
    }

    func testAccentsAndCaseAreIgnored() {
        let note = ledger(["- Elia | SPEAKER_01 | \"LA REUNIO AMB L'ELIA SERA DIMARTS QUE VE A LES DEU\" | meeting"])
        let r = LedgerVerifier.verify(note, transcript: transcript)
        XCTAssertEqual(r.removed, 0)
        XCTAssertEqual(r.flagged, 0)
    }

    func testSpokenNumbersMatchDigits() {
        // "dos mil tres cents" in the audio, "2300" in the ledger fact.
        let note = ledger(["- 2300 euros | SPEAKER_00 | \"el pressupost és de dos mil tres cents euros\" | budget"])
        let r = LedgerVerifier.verify(note, transcript: transcript)
        XCTAssertEqual(r.removed, 0)
        XCTAssertEqual(r.flagged, 0, r.text)
    }

    func testNumberWordsCollapse() {
        XCTAssertEqual(NumberWords.collapse(["dos", "mil", "tres"]), ["2003"])
        XCTAssertEqual(NumberWords.collapse(["twenty", "five", "pounds"]), ["25", "pounds"])
        XCTAssertEqual(NumberWords.collapse(["treinta", "y", "dos"]), ["32"])
        XCTAssertEqual(NumberWords.collapse(["two", "hundred", "fifty"]), ["250"])
        XCTAssertEqual(NumberWords.collapse(["eight", "fifty"]), ["8", "50"])
        XCTAssertEqual(NumberWords.collapse(["un", "dia"]), ["un", "dia"], "a lone ambiguous word stays a word")
        XCTAssertEqual(LedgerVerifier.tokens("Dos mil tres"), ["2003"])
        XCTAssertEqual(LedgerVerifier.tokens("2003"), ["2003"])
    }

    /// Security review: long runs of multipliers used to overflow Int and trap.
    func testPathologicalNumberWordRunsDoNotCrash() {
        let millions = Array(repeating: "million", count: 30)
        let hundreds = Array(repeating: "hundred", count: 30)
        let mixed = (0..<30).flatMap { _ in ["nine", "hundred", "million", "mil", "thousand"] }
        for words in [millions, hundreds, mixed, millions + hundreds + millions] {
            let out = NumberWords.collapse(words)
            XCTAssertFalse(out.isEmpty)
            XCTAssertLessThanOrEqual(out.count, words.count)
            for token in out { XCTAssertNotNil(Int(token), token); XCTAssertLessThanOrEqual(Int(token)!, 1_000_000_000_000) }
        }
        let note = ledger(["- X | S | \"" + millions.joined(separator: " ") + "\" | y"])
        _ = LedgerVerifier.verify(note, transcript: millions.joined(separator: " ") + " " + transcript)
    }

    func testSmallSpellingVariantInTheQuoteCountsAsSupport() {
        // ASR wrote "Lucidchart" as "Lucidchat": the fact is still found in its own quote.
        let t = transcript.replacingOccurrences(of: "Lucidchart", with: "Lucidchat")
        let note = ledger(["- Lucidchart | SPEAKER_01 | \"l'equip de disseny prefereix Lucidchat\" | tool"])
        XCTAssertEqual(LedgerVerifier.verify(note, transcript: t).flagged, 0)
    }

    func testEllipsisQuoteMatchesEachPart() {
        let note = ledger(["- budget | SPEAKER_00 | \"el pressupost és de… sense falta\" | amount"])
        XCTAssertEqual(LedgerVerifier.verify(note, transcript: transcript).removed, 0)
    }

    func testRowWithoutQuoteIsRemovedAndRowsWithTooFewFieldsAreKept() {
        let note = ledger([
            "- Visio | SPEAKER_01 | | tool",
            "- just a note without columns",
        ])
        let r = LedgerVerifier.verify(note, transcript: transcript)
        XCTAssertEqual(r.removed, 1)
        XCTAssertTrue(r.text.contains("- just a note without columns"))
    }

    func testPipeTableRowsAreHandledAndHeaderRowsKept() {
        let note = ledger([
            "| Fact | Who | Excerpt | Interpretation |",
            "|---|---|---|---|",
            "| Visio | SPEAKER_01 | \"fem servir Visio per als diagrames\" | tool |",
            "| Slurm | SPEAKER_00 | \"moved the Slurm cluster\" | scheduler |",
        ])
        let r = LedgerVerifier.verify(note, transcript: transcript)
        XCTAssertEqual(r.removed, 1)
        XCTAssertTrue(r.text.contains("| Fact | Who |"))
        XCTAssertTrue(r.text.contains("|---|---|---|---|"))
        XCTAssertTrue(r.text.contains("| Visio |"))
    }

    func testNoLedgerOrTinyOrUnsegmentedTranscriptLeavesTheNoteAlone() {
        let plain = "# Meeting notes\n\n## Executive summary\nText.\n"
        XCTAssertEqual(LedgerVerifier.verify(plain, transcript: transcript).text, plain)
        let note = ledger(["- X | S | \"nothing like this\" | y"])
        XCTAssertEqual(LedgerVerifier.verify(note, transcript: "too short").text, note)
        let thai = Array(repeating: "สวัสดีครับวันนี้เราจะคุยกันเรื่องโครงการใหม่ของบริษัท", count: 30).joined(separator: " ")
        XCTAssertEqual(LedgerVerifier.verify(note, transcript: thai).text, note)
    }

    func testFooterNotes() {
        XCTAssertEqual(LedgerVerifier.notes(for: .init(text: "", removed: 3, flagged: 1)),
                       ["3 ledger rows removed as unsupported by the transcript", "1 ledger row marked [unverified]"])
        XCTAssertEqual(LedgerVerifier.notes(for: .init(text: "", removed: 0, flagged: 0)), [])
    }

    // MARK: Wiring

    func testSummaryChecksRunsItOnlyForFactsFirst() {
        let note = ledger(["- Slurm | SPEAKER_00 | \"the Slurm cluster\" | x"])
        let facts = NoteContext(noteOwner: "M", userSpeaker: "u", promptStyle: .factsFirst)
        let out = SummaryChecks.apply(summary: note, transcript: transcript, context: facts)
        XCTAssertFalse(out.text.contains("Slurm"))
        XCTAssertEqual(out.notes, ["1 ledger row removed as unsupported by the transcript"])
        let classic = NoteContext(noteOwner: "M", userSpeaker: "u", promptStyle: .classic)
        XCTAssertEqual(SummaryChecks.apply(summary: note, transcript: transcript, context: classic).text, note)
    }
}
