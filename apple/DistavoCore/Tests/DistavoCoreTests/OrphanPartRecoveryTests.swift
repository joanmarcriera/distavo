import XCTest
@testable import DistavoCore

final class OrphanPartRecoveryTests: XCTestCase {

    func testNoWavPromotesPart() {
        XCTAssertEqual(OrphanPartRecovery.decide(wavSize: nil, partSize: 10_000_000), .promotePart)
    }

    func testHeaderOnlyWavDoesNotDeleteCompletePart() {
        // The bug: a 44-byte truncated WAV made recovery delete the 10 MB take.
        XCTAssertEqual(OrphanPartRecovery.decide(wavSize: 44, partSize: 10 * 1024 * 1024), .promotePart)
    }

    func testEqualSizesKeepWavAndDiscardPart() {
        XCTAssertEqual(OrphanPartRecovery.decide(wavSize: 5_000_000, partSize: 5_000_000), .discardPart)
    }

    func testLargerWavKeepsWavAndDiscardsPart() {
        XCTAssertEqual(OrphanPartRecovery.decide(wavSize: 10_000_000, partSize: 44), .discardPart)
    }

    func testUnreadablePartTouchesNothing() {
        XCTAssertEqual(OrphanPartRecovery.decide(wavSize: 44, partSize: nil), .keepBoth)
        XCTAssertEqual(OrphanPartRecovery.decide(wavSize: nil, partSize: nil), .keepBoth)
    }
}
