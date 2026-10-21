import XCTest
@testable import DistavoCore

final class DiscardPromptTests: XCTestCase {
    func testReturnNeverDeletes() {
        XCTAssertFalse(DiscardPrompt.returnDeletes)
        XCTAssertEqual(DiscardPrompt.buttonTitles.first, "Keep recording")
    }
    func testOnlyDestructiveButtonDeletes() {
        XCTAssertTrue(DiscardPrompt.shouldDelete(buttonIndex: 1))
        XCTAssertFalse(DiscardPrompt.shouldDelete(buttonIndex: 0))
        XCTAssertFalse(DiscardPrompt.shouldDelete(buttonIndex: 2))
        XCTAssertEqual(DiscardPrompt.buttonTitles[DiscardPrompt.destructiveIndex], "Delete recording")
    }
}
