import XCTest
@testable import DistavoCore

final class SummaryCleanerTests: XCTestCase {

    /// The live bug: gemma4:26b's "Step 1/2/3" preamble in front of the note,
    /// with the ledger/speakers content properly repeated inside the note —
    /// the preamble is dropped and the note starts clean.
    func testDropsLeakedStepsWhenLedgerAndSpeakersSurviveInTheNote() {
        let text = """
        ## Step 1: identify the speakers
        SPEAKER_00 is Marc, per self-introduction.

        ## Step 2: facts ledger
        - a fact | Marc | "I said this" | interpreted

        # Meeting notes

        ## Speakers
        Marc (SPEAKER_00).

        ## Facts ledger
        - a fact | Marc | "I said this" | interpreted

        ## Executive summary
        All good.
        """
        var loggedMessages: [String] = []
        let cleaned = SummaryCleaner.stripLeakedWorkingSteps(text) { loggedMessages.append($0) }
        XCTAssertTrue(cleaned.hasPrefix("# Meeting notes"))
        XCTAssertFalse(cleaned.contains("## Step 1"))
        XCTAssertFalse(cleaned.contains("## Step 2"))
        XCTAssertTrue(cleaned.contains("## Speakers"))
        XCTAssertTrue(cleaned.contains("## Facts ledger"))
        XCTAssertTrue(loggedMessages.isEmpty)
    }

    /// The ledger/speakers only exist in the discarded preamble — never
    /// silently throw the only copy away. Text is unchanged; caller is told.
    func testKeepsTextUnchangedWhenLedgerOnlyExistsInThePreamble() {
        let text = """
        ## Step 1: identify the speakers
        SPEAKER_00 is Marc.

        ## Step 2: facts ledger
        - a fact | Marc | "I said this" | interpreted

        # Meeting notes

        ## Executive summary
        All good, but the note itself never repeats speakers or the ledger.
        """
        var loggedMessages: [String] = []
        let cleaned = SummaryCleaner.stripLeakedWorkingSteps(text) { loggedMessages.append($0) }
        XCTAssertEqual(cleaned, text)
        XCTAssertEqual(loggedMessages.count, 1)
        XCTAssertTrue(loggedMessages[0].contains("discarded preamble"))
    }

    /// No leaked "## Step " heading before "# Meeting notes" — text passes
    /// through untouched (this is the normal, non-buggy case).
    func testLeavesNormalNoteUnchanged() {
        let text = "# Meeting notes\n\n## Speakers\nMarc.\n\n## Facts ledger\n- nothing"
        XCTAssertEqual(SummaryCleaner.stripLeakedWorkingSteps(text), text)
    }

    /// No "# Meeting notes" line at all — nothing to anchor on, so the text
    /// is returned unchanged (never crashes, never truncates).
    func testTextWithoutMeetingNotesHeadingIsUnchanged() {
        let text = "## Step 1: identify the speakers\nsomething went very wrong"
        XCTAssertEqual(SummaryCleaner.stripLeakedWorkingSteps(text), text)
    }

    /// A "## Step " heading AFTER "# Meeting notes" (inside the note itself,
    /// e.g. a legitimately named section) must not trigger the cleanup — only
    /// a leak in the preamble does.
    func testStepHeadingAfterMeetingNotesIsNotTreatedAsALeak() {
        let text = "# Meeting notes\n\n## Speakers\nMarc.\n\n## Step 5: something unrelated\ntext"
        XCTAssertEqual(SummaryCleaner.stripLeakedWorkingSteps(text), text)
    }
}
