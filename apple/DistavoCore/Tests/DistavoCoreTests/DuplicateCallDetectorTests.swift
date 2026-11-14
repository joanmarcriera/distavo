import XCTest
@testable import DistavoCore

/// Vikunja #4014. Synthetic names and times only; no transcript or audio is involved.
final class DuplicateCallDetectorTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func call(_ base: String, _ startOffset: Double, _ minutes: Double, sheet: Bool = false, live: Bool = false) -> CapturedCall {
        CapturedCall(base: base, start: t0.addingTimeInterval(startOffset), durationSeconds: minutes * 60,
                     hasParticipantsSheet: sheet, isLiveCapture: live)
    }

    func testPhoneAndMacCopyOfTheSameCallArePairedAndTheSheetOwnerIsPrimary() {
        let phone = call("phone-a", 9, 41)                        // starts 9 s late, runs a little longer
        let mac = call("Meeting_a", 0, 40, sheet: true, live: true)
        let pairs = DuplicateCallDetector.pairs(in: [phone, mac])
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs[0].primary.base, "Meeting_a", "the copy with the sheet wins even though it is shorter")
        XCTAssertEqual(pairs[0].secondary.base, "phone-a")
    }

    func testWithoutSheetsTheLongerIsPrimaryThenTheLiveCapture() {
        let a = call("a", 0, 30), b = call("b", 30, 28)
        XCTAssertEqual(DuplicateCallDetector.pairs(in: [a, b]).first?.primary.base, "a")
        let c = call("c", 0, 30), d = call("d", 0, 30, live: true)
        XCTAssertEqual(DuplicateCallDetector.pairs(in: [c, d]).first?.primary.base, "d")
    }

    func testBackToBackCallsAreNotPaired() {
        XCTAssertTrue(DuplicateCallDetector.pairs(in: [call("a", 0, 30), call("b", 31 * 60, 30)]).isEmpty)
    }

    func testShortMemoInsideALongCallIsNotPaired() {
        // The memo starts 20 min into the call: full overlap with itself but the starts are far apart.
        XCTAssertTrue(DuplicateCallDetector.pairs(in: [call("long", 0, 60), call("memo", 20 * 60, 3)]).isEmpty)
    }

    func testPartialOverlapBelowThresholdIsNotPaired() {
        // 30 min and 30 min, offset 12 min: overlap 18/30 = 0.6 < 0.7.
        XCTAssertTrue(DuplicateCallDetector.pairs(in: [call("a", 0, 30), call("b", 12 * 60, 30)]).isEmpty)
    }

    func testFourPairsLikeTheFieldCaseAndEachRecordingInOnePairOnly() {
        var calls: [CapturedCall] = []
        for i in 0..<4 {
            let off = Double(i) * 4 * 3600
            calls.append(call("phone-\(i)", off + 8, 30))
            calls.append(call("Meeting_\(i)", off, 30, sheet: true, live: true))
        }
        let pairs = DuplicateCallDetector.pairs(in: calls)
        XCTAssertEqual(pairs.count, 4)
        XCTAssertEqual(Set(pairs.flatMap { [$0.primary.base, $0.secondary.base] }).count, 8)
        XCTAssertTrue(pairs.allSatisfy { $0.primary.base.hasPrefix("Meeting_") })
    }

    func testAndroidContainerEndTimeGivesTheStart() {
        let end = t0.addingTimeInterval(1800)
        XCTAssertEqual(CapturedCall.startFromContainerEnd(end, durationSeconds: 1800), t0)
    }

    func testSameBaseNeverPairsWithItselfAndEmptyDurationIsIgnored() {
        XCTAssertTrue(DuplicateCallDetector.pairs(in: [call("a", 0, 30), call("a", 0, 30)]).isEmpty)
        XCTAssertTrue(DuplicateCallDetector.pairs(in: [call("a", 0, 0), call("b", 0, 30)]).isEmpty)
    }

    func testLineNamesOnlyTheOtherBase() {
        XCTAssertEqual(DuplicateCallDetector.alsoCapturedLine(otherBase: "x", isPrimary: true),
                       "Also captured as x (this note is the primary).")
    }
}
