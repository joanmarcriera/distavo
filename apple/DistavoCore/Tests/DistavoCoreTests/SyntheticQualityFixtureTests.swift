import XCTest
@testable import DistavoCore

/// Vikunja #3934, on a SYNTHETIC panel only (made-up people, company and tools; the real recordings are third-party
/// and stay local). The failure classes of the 21 Oct panel that code can catch, pinned against the deterministic
/// checks, plus the gaps that stay open (each says so in its name). Report: docs/quality-check-3934.md.
final class SyntheticQualityFixtureTests: XCTestCase {

    // SPEAKER_00 = the interviewer (Dana), SPEAKER_01 = the candidate (Ivo, the note owner).
    private let transcript = """
    [SPEAKER_00]
    Welcome Ivo. The role is tech lead for a new managed service operations team at Northwind Compute.

    [SPEAKER_01]
    Thanks Dana. Did the support model span two shifts, one for European hours and one for American hours?

    [SPEAKER_00]
    Yes, two shifts. We will run about twenty eight racks of the Rackstack 72 system in the first year.

    [SPEAKER_01]
    I have managed queues in Quillsched. Zetafabric for storage? No, never. I only watched a colleague configure Marlow once.

    [SPEAKER_00]
    That is fine. Next step is an internal conversation and then another round.
    """

    private func ledger(_ rows: [String]) -> String {
        "# Notes\n\n## Facts ledger\n" + rows.joined(separator: "\n") + "\n\n## Executive summary\nText.\n"
    }

    func testInventedRowIsRemoved() {
        let r = LedgerVerifier.verify(ledger([
            "- Has experience with Brindle | SPEAKER_01 | \"I ran Brindle in production for years\" | skill",
            "- Managed queues in Quillsched | SPEAKER_01 | \"I have managed queues in Quillsched\" | skill",
        ]), transcript: transcript)
        XCTAssertEqual(r.removed, 1)
        XCTAssertFalse(r.text.contains("Brindle"))
        XCTAssertTrue(r.text.contains("managed queues in Quillsched"))
    }

    func testRowSaidByTheInterviewerIsAttributedToHim() {
        // "The note owner asked about the role" was really the interviewer's line.
        let r = LedgerVerifier.verify(ledger([
            "- Role is tech lead for a new operations team | SPEAKER_01 | \"The role is tech lead for a new managed service operations team\" | role",
            "- Welcome | SPEAKER_01 | \"Thanks Dana. Did the support model span two shifts\" | question",
        ]), transcript: transcript)
        XCTAssertEqual(r.corrected, 1, "speaker is taken from the turn that holds the quote")
        XCTAssertTrue(r.text.contains("| SPEAKER_00 |"))
        XCTAssertTrue(r.text.contains("Thanks Dana") && r.text.contains("| SPEAKER_01 |"), "the correct row keeps its speaker")
    }

    func testWrongFigureIsRemoved() {
        let r = LedgerVerifier.verify(ledger([
            "- About 82 racks in the first year | SPEAKER_00 | \"about twenty eight racks of the Rackstack 72 system\" | scale",
            "- About 28 racks in the first year | SPEAKER_00 | \"about twenty eight racks of the Rackstack 72 system\" | scale",
        ]), transcript: transcript)
        XCTAssertEqual(r.removed, 1)
        XCTAssertTrue(r.text.contains("About 28 racks"))
    }

    func testSpokenVocabularyCanBeRepairedByAReplacementRule() {
        let heard = "We will run about twenty eight racks of the Rackstack sevnty too system"
        let fixed = Vocabulary.applyReplacements(heard, rules: [ReplacementRule(from: "Rackstack sevnty too", to: "Rackstack 72")])
        XCTAssertEqual(fixed, "We will run about twenty eight racks of the Rackstack 72 system")
    }

    // MARK: Known gaps (these pass today; flip them when the gap is closed)

    /// The candidate said "Zetafabric for storage? No, never." A ledger row claiming Zetafabric experience quotes real words,
    /// contains its key token and its figures, so no deterministic rule sees the negation.
    func testGap_negatedQuoteSurvivesTheVerifier() {
        let r = LedgerVerifier.verify(ledger([
            "- Has Zetafabric experience for storage | SPEAKER_01 | \"Zetafabric for storage? No, never\" | skill",
        ]), transcript: transcript)
        XCTAssertEqual(r.removed, 0)
        XCTAssertEqual(r.flagged, 0)
        XCTAssertTrue(r.text.contains("Has Zetafabric experience"), "gap: negation is not read; a model or a reviewer must catch it")
    }

    /// A token from another language inside an English turn (the "vakt dekking ... Amerikan" drift) is not touched:
    /// nothing in the cleaner knows the language of a word. Closing it needs a re-decode (cf. HoleRecovery), not a regex.
    func testGap_languageDriftInsideATurnIsNotDetected() {
        let drifted = Segment(speaker: "SPEAKER_01", text: "One vakt dekking the European hours and second vakt dekking the Amerikaanse hours", start: 0, end: 8)
        let out = TranscriptCleaner.clean([drifted])
        XCTAssertTrue(out.contains("vakt dekking"), "gap: drift passes the cleaner unchanged")
    }
}
