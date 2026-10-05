// CalendarAttendeesMentionedTests - which calendar attendees survive the "Who was in this meeting?" edit (Vikunja #2946).
import XCTest
@testable import DistavoCore

final class CalendarAttendeesMentionedTests: XCTestCase {
    func testMentionedKeepsOnlyNamesLeftInTheParticipants() {
        let all = ["Ada Lovelace", "Zoë", "Bob"]
        XCTAssertEqual(CalendarAttendees.mentioned(in: "Other participants: ada lovelace, zoe", attendees: all),
                       ["Ada Lovelace", "Zoë"])
        XCTAssertEqual(CalendarAttendees.mentioned(in: nil, attendees: all), [])
        XCTAssertEqual(CalendarAttendees.mentioned(in: "  ", attendees: all), [])
        XCTAssertEqual(CalendarAttendees.mentioned(in: "Ada Lovelace, Zoë, Bob", attendees: all), all)
    }
}
