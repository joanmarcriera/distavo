import XCTest
@testable import DistavoCore

/// Vikunja #6354: the note's own "Possible transcription corrections" are applied to the note
/// body. Synthetic fixture (invented company and terms), no call content.
final class TranscriptionCorrectionsTests: XCTestCase {

    private let transcript = "We should open the Acme Bank account. The Acme Bank card arrives Monday. Ask about POYE and the Starlin invoice."

    private let note = """
    ## Executive summary
    Set up Acme Bank and Starlin accounts; POYE is due monthly.

    ## Decisions
    - Open Acme Bank first.

    ## Possible transcription corrections
    - heard "Acme Bank", probably "Acme Banc"
    - heard "POYE/POE", probably "PAYE"
    - heard "Starlin", probably "Starling"
    - heard "Missing", probably "Present"

    ## Suggested follow-up email
    Hi, thanks about the Acme Bank card.
    """

    func testCorrectionsReplaceEverywhereOutsideTheSectionAndSectionStaysAsAudit() {
        let r = TranscriptionCorrections.apply(note, transcript: transcript)
        let body = r.text.components(separatedBy: "## Possible transcription corrections")
        let before = body[0], after = body[1].components(separatedBy: "## Suggested follow-up email")
        XCTAssertFalse(before.contains("Acme Bank"))
        XCTAssertTrue(before.contains("Acme Banc and Starling accounts; PAYE is due"))
        XCTAssertTrue(after[1].contains("Acme Banc card"))
        // The audit list is untouched.
        XCTAssertTrue(after[0].contains("heard \"Acme Bank\", probably \"Acme Banc\""))
        XCTAssertEqual(r.applied.map(\.heard), ["Acme Bank", "POYE", "Starlin"])
        XCTAssertEqual(r.applied.map(\.corrected), ["Acme Banc", "PAYE", "Starling"])
    }

    func testTermAbsentFromTranscriptOrBodyIsNotApplied() {
        let r = TranscriptionCorrections.apply(note, transcript: transcript)
        XCTAssertFalse(r.applied.contains { $0.heard == "Missing" })
    }

    func testWholeWordOnlyAndNoSectionMeansNoChange() {
        let n = "## Summary\nPOYEs and POYE.\n\n## Possible transcription corrections\n- heard \"POYE\", probably \"PAYE\"\n"
        let r = TranscriptionCorrections.apply(n, transcript: "the POYE form")
        XCTAssertTrue(r.text.contains("POYEs and PAYE."))
        XCTAssertEqual(TranscriptionCorrections.apply("plain", transcript: "x").text, "plain")
        XCTAssertEqual(TranscriptionCorrections.apply("none", transcript: "x").applied.count, 0)
    }

    func testSummaryChecksAppliesAndReportsFooterNote() {
        let out = SummaryChecks.apply(summary: note, transcript: transcript, context: NoteContext(noteOwner: "A", userSpeaker: "S"))
        XCTAssertTrue(out.text.contains("Acme Banc card"))
        XCTAssertTrue(out.notes.contains { $0.contains("3 transcription corrections applied") })
    }
}
