import XCTest
@testable import DistavoCore

final class InPersonBoxPolicyTests: XCTestCase {
    func testHiddenWhenCallAudioWasHeard() {
        XCTAssertFalse(InPersonBoxPolicy.make(systemAudioHeard: true).visible)
    }

    func testShownWithHelpWhenNoCallAudio() {
        let p = InPersonBoxPolicy.make(systemAudioHeard: false)
        XCTAssertTrue(p.visible)
        XCTAssertTrue(p.help.contains("heard nothing from the other side"))
        XCTAssertTrue(p.tooltip.contains("number of people"))
        XCTAssertTrue(p.title.contains("no call audio"))
    }
}
