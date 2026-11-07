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

    /// Review 2026-11-07: a corrected form that contains the heard term must not be extended twice, and a second
    /// pass over the output must change nothing.
    func testCorrectedFormContainingHeardTermIsNotDoubled() {
        let n = "## Summary\nStarling and Starling Bank agreed.\n\n## Possible transcription corrections\n- heard \"Starling\", probably \"Starling Bank\"\n"
        let t = "We met Starling about it."
        let r = TranscriptionCorrections.apply(n, transcript: t)
        XCTAssertTrue(r.text.contains("Starling Bank and Starling Bank agreed."), r.text)
        XCTAssertFalse(r.text.contains("Bank Bank"))
        XCTAssertEqual(TranscriptionCorrections.apply(r.text, transcript: t).text, r.text)
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

    // MARK: review 2026-11-07 follow-ups

    /// Links, bare URLs and code spans are not prose: a heard word inside them stays.
    func testNothingIsRewrittenInsideUrlsOrCode() {
        let n = "## Summary\nStarlin said so: [Starlin](https://starlin.example/Starlin) and https://starlin.example/x, `Starlin --help`.\n\n```\nStarlin run\n```\n\n## Possible transcription corrections\n- heard \"Starlin\", probably \"Starling\"\n"
        let r = TranscriptionCorrections.apply(n, transcript: "ask Starlin")
        XCTAssertTrue(r.text.contains("Starling said so: [Starling](https://starlin.example/Starlin)"), r.text)
        XCTAssertTrue(r.text.contains("https://starlin.example/x, `Starlin --help`."), r.text)
        XCTAssertTrue(r.text.contains("```\nStarlin run\n```"), r.text)
    }

    /// The section is found whatever the heading level, trailing colon or bold the model used.
    func testHeadingVariantsAreRecognised() {
        for h in ["### Possible transcription corrections", "## Possible transcription corrections:", "## **Possible transcription corrections**", "# POSSIBLE TRANSCRIPTION CORRECTIONS"] {
            let n = "## Summary\nPOYE due.\n\n\(h)\n- heard \"POYE\", probably \"PAYE\"\n"
            XCTAssertTrue(TranscriptionCorrections.apply(n, transcript: "the POYE form").text.contains("PAYE due."), h)
        }
    }

    /// A line that merely starts with '#' (a hashtag, "#2 item") is not a heading and does not end the section.
    func testHashLineInsideSectionDoesNotEndIt() {
        let n = "## Summary\nPOYE and Starlin.\n\n## Possible transcription corrections\n- heard \"POYE\", probably \"PAYE\"\n#2 also\n- heard \"Starlin\", probably \"Starling\"\n"
        let r = TranscriptionCorrections.apply(n, transcript: "POYE Starlin")
        XCTAssertEqual(r.applied.map(\.heard), ["POYE", "Starlin"])
    }

    func testOptOutLeavesTheBodyAlone() {
        let ctx = NoteContext(noteOwner: "A", userSpeaker: "S")
        let out = SummaryChecks.apply(summary: note, transcript: transcript, context: ctx, applyCorrections: false)
        XCTAssertTrue(out.text.contains("Acme Bank"))
        XCTAssertFalse(out.notes.contains { $0.contains("correction") })
    }

    func testApplyCorrectionsFlagDefaultsOnAndRoundTrips() throws {
        XCTAssertTrue(SummariseConfig().applyCorrections)
        let old = try JSONDecoder().decode(SummariseConfig.self, from: Data("{}".utf8))
        XCTAssertTrue(old.applyCorrections)
        let off = try JSONDecoder().decode(SummariseConfig.self, from: Data("{\"apply_corrections\":false}".utf8))
        XCTAssertFalse(off.applyCorrections)
    }
}
