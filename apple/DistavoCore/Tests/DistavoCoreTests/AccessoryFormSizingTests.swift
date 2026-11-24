import XCTest
@testable import DistavoCore

final class AccessoryFormSizingTests: XCTestCase {
    func testTallContentIsNeverClippedBelowItsFittingHeight() {
        // The fully populated sheet measured 432 pt against the old fixed 350 (#6982/#6983).
        let f = AccessoryFormSizing.frame(fittingWidth: 440, fittingHeight: 431.5)
        XCTAssertEqual(f.height, 432)
        XCTAssertGreaterThanOrEqual(f.height, 431.5)
    }
    func testSmallContentKeepsMinimumSize() {
        let f = AccessoryFormSizing.frame(fittingWidth: 300, fittingHeight: 40)
        XCTAssertEqual(f.width, AccessoryFormSizing.minimumWidth)
        XCTAssertEqual(f.height, AccessoryFormSizing.minimumHeight)
    }
    func testWideContentWidens() {
        XCTAssertEqual(AccessoryFormSizing.frame(fittingWidth: 520.2, fittingHeight: 200).width, 521)
    }
    func testNonFiniteMeasurementFallsBackToMinimum() {
        let f = AccessoryFormSizing.frame(fittingWidth: .nan, fittingHeight: .infinity)
        XCTAssertEqual(f.width, AccessoryFormSizing.minimumWidth)
        XCTAssertEqual(f.height, AccessoryFormSizing.minimumHeight)
    }
}
