import XCTest
@testable import DistavoCore

/// The two-part note footer (1.19): provenance line + optional summary line.
final class NoteFooterLinesTests: XCTestCase {
    private let provenance = "\n\n---\n_Transcribed on this Mac with Whisper Small._"

    func testNoNotesLeavesTheFooterUnchanged() {
        XCTAssertEqual(NoteFooterLines.footer(provenance: provenance, summaryNotes: []), provenance)
        XCTAssertEqual(NoteFooterLines.footer(provenance: "", summaryNotes: ["", "  "]), "")
    }

    func testSummaryLineFollowsProvenance() {
        let footer = NoteFooterLines.footer(provenance: provenance,
                                            summaryNotes: ["2 ledger rows removed", "Template: Stand-up."])
        XCTAssertEqual(footer, provenance + "\n\n_Summary: 2 ledger rows removed. Template: Stand-up._")
    }

    func testSummaryLineAloneGetsItsOwnRule() {
        XCTAssertEqual(NoteFooterLines.footer(provenance: "", summaryNotes: ["Note language: Catalan"]),
                       "\n\n---\n_Summary: Note language: Catalan._")
    }

    func testRegenerateDropsTheOldSummaryLine() {
        let old = NoteFooterLines.footer(provenance: provenance, summaryNotes: ["1 ledger row removed"])
        XCTAssertEqual(NoteFooterLines.provenanceOnly(old), provenance)
        XCTAssertEqual(NoteFooterLines.provenanceOnly(provenance), provenance)
    }

    func testProvenanceCarriesTranscriberNotes() {
        let footer = NoteProvenance.footer(engine: "E", detections: [],
                                           notes: ["Recovered 12 s of speech the first pass missed."])
        XCTAssertEqual(footer, "\n\n---\n_Transcribed on this Mac with E. Recovered 12 s of speech the first pass missed._")
        XCTAssertEqual(Pipeline.provenanceFooter(from: ["engine": "E", "footer_notes": ["X."]]),
                       "\n\n---\n_Transcribed on this Mac with E. X._")
    }

    func testDefaultChecksPassTheSummaryThrough() {
        var ctx = NoteContext(noteOwner: "Me", userSpeaker: "unknown")
        XCTAssertEqual(SummaryChecks.apply(summary: "## A\nb", transcript: "t", context: ctx),
                       SummaryCheckOutcome(text: "## A\nb"))
        ctx.summaryNotes = ["Template: X"]
        XCTAssertEqual(SummaryChecks.apply(summary: "s", transcript: "t", context: ctx).notes, ["Template: X"])
    }
}
