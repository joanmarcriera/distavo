import XCTest
@testable import DistavoCore

final class SpeakerSuggestionsTests: XCTestCase {
    // Synthetic people only.
    private func hints(role: String?, others: String, terms: [String] = []) -> SpeakerHints {
        var parts: [String] = []
        if let role { parts.append("The note owner (me): \(role)") }
        if !others.isEmpty { parts.append("Other participants: \(others)") }
        return SpeakerHints(count: 2, participants: parts.joined(separator: ". "), terms: terms)
    }

    func testRoleAndOthersParse() {
        let p = "The note owner (me): candidate. Other participants: Ada Lovelace, recruiter"
        XCTAssertEqual(SpeakerSuggestions.role(in: p), "candidate")
        XCTAssertEqual(SpeakerSuggestions.others(in: p), "Ada Lovelace, recruiter")
    }
    func testLastUsedRoleAndOthers() {
        let s = SpeakerSuggestions.make(history: [hints(role: "host", others: "Ada Lovelace")], calendarOthers: "")
        XCTAssertEqual(s.role, "host"); XCTAssertEqual(s.roleOrigin, .lastUsed)
        XCTAssertEqual(s.others, "Ada Lovelace"); XCTAssertEqual(s.othersOrigin, .lastUsed)
    }
    func testCalendarBeatsLastUsedForOthers() {
        let s = SpeakerSuggestions.make(history: [hints(role: nil, others: "Ada Lovelace")], calendarOthers: "Grace Hopper")
        XCTAssertEqual(s.others, "Grace Hopper"); XCTAssertEqual(s.othersOrigin, .calendar)
    }
    func testTermsOnlyFromSameContactNeverJustLatest() {
        let history = [hints(role: "host", others: "Grace Hopper", terms: ["Slurm", "Bull"]),
                       hints(role: "host", others: "Ada Lovelace", terms: ["WWT", "NVL72"])]
        // Ada's call: her own terms, not the newer call's.
        let ada = SpeakerSuggestions.make(history: history, calendarOthers: "Ada Lovelace")
        XCTAssertEqual(ada.terms, ["WWT", "NVL72"]); XCTAssertEqual(ada.termsOrigin, .sameContact)
        // A stranger gets no terms at all.
        XCTAssertEqual(SpeakerSuggestions.make(history: history, calendarOthers: "Linus Torvalds").terms, [])
    }
    func testNoHistoryIsEmpty() {
        XCTAssertEqual(SpeakerSuggestions.make(history: [], calendarOthers: ""), .empty)
    }
}
