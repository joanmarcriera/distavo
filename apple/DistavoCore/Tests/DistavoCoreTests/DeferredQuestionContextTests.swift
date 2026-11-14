import XCTest
@testable import DistavoCore

/// Vikunja #4021: what the deferred "who was there?" form shows. Invented data only; fixed time zone and dates,
/// nothing reads the clock or the global time zone.
final class DeferredQuestionContextTests: XCTestCase {
    let utc = TimeZone(identifier: "UTC")!
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)   // fixed instant

    func build(calendar: CalendarMatch? = nil, scratchpad: ScratchpadNotes? = nil,
               bookmarks: RecordingBookmarks? = nil,
               segments: [TranscriptSegments.Segment] = []) -> DeferredQuestionContext {
        DeferredQuestionContext.build(callApp: "Teams", recordingStart: t0, durationSeconds: 900, timeZone: utc,
                                      calendar: calendar, scratchpad: scratchpad, bookmarks: bookmarks, segments: segments)
    }

    func match(title: String = "Sync", attendees: [String] = []) -> CalendarMatch {
        CalendarMatch(title: title, start: t0, end: t0.addingTimeInterval(1800), attendees: attendees)
    }

    func testNothingKnownIsEmptyButKeepsTheContextLine() {
        let c = build()
        XCTAssertTrue(c.isEmpty)
        XCTAssertTrue(c.contextLine.hasPrefix("Teams, "), c.contextLine)
        XCTAssertTrue(c.contextLine.hasSuffix(", 15 min"), c.contextLine)
    }

    func testAttendeesKeepOnlyPlausibleNamesDedupedAndCapped() {
        let raw = ["Dana Whitfield", "dana whitfield", "mailto:x@example.com", "<b>Eve</b>", "Frank O'Neil",
                   "https://evil.example/x"] + (1...20).map { "Guest \($0)" }
        let c = build(calendar: match(attendees: raw))
        XCTAssertEqual(Array(c.attendees.prefix(2)), ["Dana Whitfield", "Frank O'Neil"])
        XCTAssertFalse(c.attendees.contains { $0.contains("<") || $0.contains("@") || $0.contains("/") })
        XCTAssertLessThanOrEqual(c.attendees.count, DeferredQuestionContext.maxAttendees)
    }

    func testEventTitleLosesControlAndBidiCharactersAndIsCapped() {
        let hostile = "Budget\u{202E}review\n\t  Q4\u{200B}"
        XCTAssertEqual(build(calendar: match(title: hostile)).eventTitle, "Budgetreview Q4")
        XCTAssertNil(build(calendar: match(title: " \u{200B}\n ")).eventTitle)
        let long = String(repeating: "a", count: 300)
        XCTAssertEqual(build(calendar: match(title: long)).eventTitle?.count, DeferredQuestionContext.maxTitleChars + 1)
    }

    func testTypedNotesPutFlaggedFirstAndAreCapped() {
        let lines = (1...8).map { ScratchpadNotes.Line(offsetSeconds: $0 * 10, text: "note \($0)", flagged: $0 == 7) }
        let c = build(scratchpad: ScratchpadNotes(lines: lines))
        XCTAssertEqual(c.typedNotes.first, "note 7")
        XCTAssertEqual(c.typedNotes.count, DeferredQuestionContext.maxNotes)
        XCTAssertEqual(c.typedNotes[1], "note 1")
    }

    func testScratchpadTextIsSanitisedBeforeShowing() {
        let pad = ScratchpadNotes(lines: [.init(offsetSeconds: 1, text: "Craig {from} Pure\nabout   Common.ai")])
        XCTAssertEqual(build(scratchpad: pad).typedNotes, ["Craig (from) Pure about Common.ai"])
    }

    func testKeyMomentsAreInTimeOrderWithTimestampWhenUnlabelled() {
        let marks = RecordingBookmarks(marks: [.init(offsetSeconds: 125, label: nil),
                                               .init(offsetSeconds: 30, label: " Pricing agreed ")])
        let c = build(bookmarks: marks)
        XCTAssertEqual(c.keyMoments, ["Pricing agreed", ScratchpadNotes.timestamp(125)])
    }

    func testSpeakerLinesComeFromSegmentsAndMakeTheContextNonEmpty() {
        let segs = [TranscriptSegments.Segment(start: 6, end: 12,
                    text: "We are hiring for the London team and the budget is 85000 pounds.", speaker: "SPEAKER_00")]
        let c = build(segments: segs)
        XCTAssertFalse(c.isEmpty)
        XCTAssertEqual(c.speakers.map(\.speaker), ["SPEAKER_00"])
    }

    func testNothingFromTheCalendarIsAddedWhenThereIsNoMatch() {
        let c = build(calendar: nil, scratchpad: ScratchpadNotes(), bookmarks: nil)
        XCTAssertNil(c.eventTitle)
        XCTAssertTrue(c.attendees.isEmpty)
    }
}
