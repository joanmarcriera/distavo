import XCTest
@testable import DistavoCore

/// Vikunja #3943 points 2 and 3: the source line and the recent-people quick-pick. Synthetic names only.
final class SpeakerQuickPickTests: XCTestCase {
    private func h(_ others: String) -> SpeakerHints {
        SpeakerHints(count: 2, participants: "The note owner (me): host. Other participants: \(others)", terms: [])
    }

    func testRecentSetsAreDistinctNewestFirstAndCapped() {
        let history = [h("Ada Lovelace"), h("Grace Hopper, Ada Lovelace"), h("ada lovelace"), h("Alan Turing"),
                       h("Hopper Grace, Lovelace Ada")]
        let sets = SpeakerSuggestions.recentParticipantSets(history: history, limit: 3)
        XCTAssertEqual(sets, ["Ada Lovelace", "Grace Hopper, Ada Lovelace", "Alan Turing"])
    }

    func testSetsSkipSheetsWithoutOthers() {
        let none = SpeakerHints(count: nil, participants: "The note owner (me): host", terms: [])
        XCTAssertEqual(SpeakerSuggestions.recentParticipantSets(history: [none, SpeakerHints()]), [])
    }

    func testSourceLineNamesEveryPrefilledValue() {
        var s = SpeakerSuggestions.empty
        XCTAssertNil(s.sourceLine)
        s.role = "host"; s.roleOrigin = .lastUsed
        s.others = "Ada Lovelace"; s.othersOrigin = .calendar
        s.terms = ["Foo"]; s.termsOrigin = .sameContact
        XCTAssertEqual(s.sourceLine,
                       "Suggested: role (last used) · participants (calendar) · terms (same contact). Edit or clear any of it.")
        s.terms = []
        XCTAssertEqual(s.sourceLine?.contains("terms"), false)
    }
}
