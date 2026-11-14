import XCTest
@testable import DistavoCore

/// Vikunja #3953: num_speakers=2 must not merge a third voice. Synthetic names only.
final class SpeakerCountReconcileTests: XCTestCase {
    private let three = "Owner: Alex. Other participants: Sam (Acme), Robin (Acme)"

    func testExplicitHintCountWins() {
        XCTAssertEqual(SpeakerHints.reconciledCount(hintCount: 2, participants: three, configured: 2), 2)
    }
    func testListedPeopleRaiseConfiguredCount() {
        XCTAssertEqual(SpeakerHints.reconciledCount(hintCount: nil, participants: three, configured: 2), 3)
    }
    func testAutoStaysAuto() {
        XCTAssertEqual(SpeakerHints.reconciledCount(hintCount: nil, participants: three, configured: 0), 0)
    }
    func testNeverLowersConfiguredCount() {
        XCTAssertEqual(SpeakerHints.reconciledCount(hintCount: nil, participants: "Other participants: Sam", configured: 4), 4)
    }
    func testNoParticipantsKeepsConfigured() {
        XCTAssertEqual(SpeakerHints.reconciledCount(hintCount: nil, participants: nil, configured: 2), 2)
        XCTAssertEqual(SpeakerHints.reconciledCount(hintCount: 0, participants: "free text", configured: 2), 2)
    }
}
