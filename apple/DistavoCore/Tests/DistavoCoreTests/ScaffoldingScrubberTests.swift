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

    func testSummaryChecksAppliesIt() {
        let out = SummaryChecks.apply(summary: leaked, transcript: "we ship on Friday", context: NoteContext(noteOwner: "Alex", userSpeaker: "SPEAKER_00"))
        XCTAssertFalse(out.text.contains("Step 1"))
    }
}
