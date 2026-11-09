import XCTest
@testable import DistavoCore

/// Synthetic model output only (Vikunja #4010): no real meeting content.
final class ScaffoldingScrubberTests: XCTestCase {
    private let leaked = """
    ## Step 1: Identify the speakers
    SPEAKER_00 is Alex (note owner).

    ## Step 2: Facts ledger
    - --- | --- | --- | ---
    | Fact | Quote |

    ## Step 3: The notes

    # Meeting notes

    ### # Summary
    The team agreed to ship on Friday.

    #### ## Speakers
    - Alex (note owner)

    #### ## Facts ledger
    | Fact | Quote |
    |---|---|
    | Ship Friday | "we ship on Friday" |

    ## Decisions  See above.

    ## Actions
    - Alex to tag the build.

    Note: The output only includes the notes section, as per the instructions.
    """

    private let banned = ["Step 1", "Step 2", "Step 3", "using evidence only", "See above",
                          "as per the instructions", "#### ##", "### #", "- --- |"]

    func testLeakedScaffoldingIsRemoved() {
        let out = ScaffoldingScrubber.scrub(leaked)
        for b in banned { XCTAssertFalse(out.contains(b), "still contains \(b):\n\(out)") }
        XCTAssertEqual(out.components(separatedBy: "Facts ledger").count - 1, 1, out)
        XCTAssertTrue(out.contains("# Meeting notes"))
        XCTAssertTrue(out.contains("## Summary"))
        XCTAssertTrue(out.contains("| Ship Friday |"))
        XCTAssertTrue(out.contains("Alex to tag the build."))
    }

    func testStepSectionWithoutLaterCopyIsRenamedNotLost() {
        let out = ScaffoldingScrubber.scrub("## Step 1: Identify the speakers\n- Sam (note owner)\n\n## Actions\n- Sam to call.")
        XCTAssertEqual(out, "## Speakers\n- Sam (note owner)\n\n## Actions\n- Sam to call.")
    }

    func testInstructionSentenceDropped() {
        let out = ScaffoldingScrubber.scrub("# Meeting notes\nDecide which speaker label is the note owner, using evidence only.\n## Summary\nShort.")
        XCTAssertEqual(out, "# Meeting notes\n## Summary\nShort.")
    }

    func testCleanNoteIsByteIdentical() {
        let clean = "# Meeting notes\n\n## Summary\nWe met.\n\n## Speakers\n- Alex\n\n## Facts ledger\n| a | b |\n|---|---|\n| 1 | 2 |\n"
        XCTAssertEqual(ScaffoldingScrubber.scrub(clean), clean)
    }

    // Review of k (2026-11-09, distavo-review lane): the scrubber must not delete real note content.

    /// The prompt itself says: if nothing was likely mis-transcribed, write "none". That answer is content.
    func testNoneSectionThePromptAsksForIsKept() {
        let note = "# Meeting notes\n\n## Summary\nWe met.\n\n## Possible transcription corrections\nnone\n\n## Decisions\nN/A\n"
        XCTAssertEqual(ScaffoldingScrubber.scrub(note), note)
    }

    /// "as per the instructions" / "using evidence only" are ordinary English in a meeting note.
    func testOrdinaryLinesThatShareAMarkerPhraseAreKept() {
        let note = """
        # Meeting notes

        ## Actions
        - Ana will configure the server as per the instructions in the runbook.
        - The panel will decide using evidence only from the audit.
        - Check the output as per the instructions from legal.
        Note: deploy as per the instructions in the wiki.
        """
        XCTAssertEqual(ScaffoldingScrubber.scrub(note), note)
    }

    /// A meeting about a plan may have its own "Step N" headings; only the prompt's steps are scaffolding.
    func testRealStepHeadingsInTheNoteAreKept() {
        let note = "# Meeting notes\n\n## Migration plan\n### Step 1: Back up the database\n- Ana runs the backup.\n### Step 2: Switch DNS\n- Joan flips the record.\n"
        XCTAssertEqual(ScaffoldingScrubber.scrub(note), note)
        // Sonnet review: substring matches ("speakers", "notes") were too wide; only the prompt's own titles count.
        let event = "# Meeting notes\n\n## Speakers\n- Ana\n\n## Conference plan\n### Step 2: Confirm the speakers\n- Ana emails them.\n### Step 3: Write up the notes\n- Joan.\n"
        XCTAssertEqual(ScaffoldingScrubber.scrub(event), event)
    }

    /// The meta line still goes, with or without a "Note:" prefix.
    func testMetaLinesAboutTheOutputStillDropped() {
        let out = ScaffoldingScrubber.scrub("# Meeting notes\n## Summary\nShort.\n(Note: as per the instructions, only the notes are shown.)\nThe output only includes the notes section.")
        XCTAssertEqual(out, "# Meeting notes\n## Summary\nShort.")
    }

    func testSummaryChecksAppliesIt() {
        let out = SummaryChecks.apply(summary: leaked, transcript: "we ship on Friday", context: NoteContext(noteOwner: "Alex", userSpeaker: "SPEAKER_00"))
        XCTAssertFalse(out.text.contains("Step 1"))
    }
}
