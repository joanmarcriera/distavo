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

    /// Drive 1246 (LOW): the owner's typed Quick Notes ride under "## Highlights" verbatim; a correction must not
    /// rewrite what the owner wrote themselves, while the rest of the body is still corrected.
    func testOwnersHighlightsAreNeverRewritten() {
        let withHighlights = """
        ## Executive summary
        Open Acme Bank first.

        ## Highlights
        - Ask about the Acme Bank card

        ## Decisions
        - Open Acme Bank first.

        ## Possible transcription corrections
        - heard "Acme Bank", probably "Acme Banc"
        """
        let r = TranscriptionCorrections.apply(withHighlights, transcript: transcript)
        XCTAssertTrue(r.text.contains("- Ask about the Acme Bank card"), r.text)
        XCTAssertTrue(r.text.contains("Open Acme Banc first."), r.text)
        XCTAssertFalse(r.text.contains("- Open Acme Bank first."), r.text)
    }

    /// Reviewer: a heading-like line inside a code fence must not split the body (it would unbalance the fence).
    func testHashLineInsideFenceDoesNotSplitTheBody() {
        let fenced = """
        ## Summary
        Run this:
        ```
        # Acme Bank comment
        echo Acme Bank
        ```
        Then open Acme Bank.

        ## Possible transcription corrections
        - heard "Acme Bank", probably "Acme Banc"
        """
        let r = TranscriptionCorrections.apply(fenced, transcript: transcript)
        XCTAssertTrue(r.text.contains("# Acme Bank comment\necho Acme Bank"), "code stays untouched: " + r.text)
        XCTAssertTrue(r.text.contains("Then open Acme Banc."), r.text)
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
        let out = SummaryChecks.apply(summary: note, transcript: transcript, context: NoteContext(noteOwner: "A", userSpeaker: "S"),
                                      applyCorrections: true)
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
        for h in ["### Possible transcription corrections", "## Possible transcription corrections:", "## **Possible transcription corrections**", "# POSSIBLE TRANSCRIPTION CORRECTIONS", "  ## Possible transcription corrections", "## Possible transcription corrections ##"] {
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

    /// Review A (drive-review-2026-11-09): a key that changes behaviour decodes to off for a config that predates it;
    /// only a fresh install (`recommendedForThisMac`) gets it on.
    func testApplyCorrectionsIsOffForOldConfigsAndOnForFreshInstalls() throws {
        XCTAssertFalse(SummariseConfig().applyCorrections)
        let old = try JSONDecoder().decode(SummariseConfig.self, from: Data("{}".utf8))
        XCTAssertFalse(old.applyCorrections)
        let oldFull = try JSONDecoder().decode(Config.self, from: Data("{\"summarise\":{\"backend\":\"server\"}}".utf8))
        XCTAssertFalse(oldFull.summarise.applyCorrections)
        let on = try JSONDecoder().decode(SummariseConfig.self, from: Data("{\"apply_corrections\":true}".utf8))
        XCTAssertTrue(on.applyCorrections)
        let off = try JSONDecoder().decode(SummariseConfig.self, from: Data("{\"apply_corrections\":false}".utf8))
        XCTAssertFalse(off.applyCorrections)
        for supported in [true, false] {
            XCTAssertTrue(Config.recommendedForThisMac(embeddedSupported: supported, memoryBytes: 16 << 30)
                .summarise.applyCorrections, "embeddedSupported=\(supported)")
        }
        let enc = try JSONEncoder().encode(SummariseConfig())
        XCTAssertTrue(String(decoding: enc, as: UTF8.self).contains("\"apply_corrections\":false"))
    }

    /// Review A: facts-ledger rows quote the transcript verbatim and were verified against it by `LedgerVerifier`;
    /// a correction must not rewrite them (a rewritten quote no longer matches what was said), while the same word
    /// in the prose is still corrected.
    func testLedgerQuotesAreNeverRewritten() {
        let withLedger = """
        ## Executive summary
        Open Acme Bank first.

        ## Facts ledger
        - Open the account | SPEAKER_00 | "We should open the Acme Bank account." | stated
        | Card arrives Monday | SPEAKER_01 | "The Acme Bank card arrives Monday." | stated |

        ## Decisions
        - Open Acme Bank first.

        ## Possible transcription corrections
        - heard "Acme Bank", probably "Acme Banc"
        """
        let r = TranscriptionCorrections.apply(withLedger, transcript: transcript)
        XCTAssertTrue(r.text.contains("\"We should open the Acme Bank account.\""), r.text)
        XCTAssertTrue(r.text.contains("\"The Acme Bank card arrives Monday.\""), r.text)
        XCTAssertTrue(r.text.contains("Open Acme Banc first."), r.text)
        XCTAssertFalse(r.text.contains("- Open Acme Bank first."), r.text)
        XCTAssertEqual(r.applied.map(\.heard), ["Acme Bank"])
    }

    /// Same guarantee through the shared entry point, with the verifier in front of it (facts-first style).
    func testLedgerQuoteSurvivesSummaryChecksWithCorrectionsOn() {
        var ctx = NoteContext(noteOwner: "A", userSpeaker: "S"); ctx.promptStyle = .factsFirst
        let longTranscript = transcript + " " + String(repeating: "We keep talking about the plan for the week. ", count: 6)
        let text = """
        ## Executive summary
        Open Acme Bank first.

        ## Facts ledger
        - Open the account | SPEAKER_00 | "We should open the Acme Bank account." | stated

        ## Possible transcription corrections
        - heard "Acme Bank", probably "Acme Banc"
        """
        let out = SummaryChecks.apply(summary: text, transcript: longTranscript, context: ctx, applyCorrections: true)
        XCTAssertTrue(out.text.contains("\"We should open the Acme Bank account.\""), out.text)
        XCTAssertTrue(out.text.contains("Open Acme Banc first."), out.text)
    }
}
