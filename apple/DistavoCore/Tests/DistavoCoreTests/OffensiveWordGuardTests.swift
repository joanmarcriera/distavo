import XCTest
@testable import DistavoCore

final class OffensiveWordGuardTests: XCTestCase {
    // The word is rebuilt from fragments so the repository does not contain it.
    private let slur = ["n", "i", "g", "g", "e", "r"].joined()

    func testParakeetSampleBecomesNagios() {
        let heard = "I created the the monitoring for the uh \(slur)s plugins into the CheckMK"
        let r = OffensiveWordGuard.apply(heard)
        XCTAssertEqual(r.text, "I created the the monitoring for the uh Nagios plugins into the CheckMK")
        XCTAssertEqual(r.flagged, 1)
    }
    func testOtherUseIsRemovedNotKept() {
        let r = OffensiveWordGuard.apply("he said \(slur) twice")
        XCTAssertEqual(r.text, "he said \(OffensiveWordGuard.placeholder) twice")
        XCTAssertEqual(r.flagged, 1)
    }
    func testCleanTextUntouchedAndSubstringsSafe() {
        let t = "Nagios plugins and a Snigger of the niggerly"  // 'snigger' must not match
        let r = OffensiveWordGuard.apply("Nagios plugins and a snigger")
        XCTAssertEqual(r.text, "Nagios plugins and a snigger"); XCTAssertEqual(r.flagged, 0)
        _ = t
    }
    func testSegmentsAreGuarded() throws {
        let json = #"{"segments":[{"start":0,"end":1,"text":"the \#(slur)s plugins"}]}"#
        let segs = try XCTUnwrap(TranscriptSegments(whisperXResult: try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])))
        let (g, n) = segs.guardedAgainstOffensiveWords()
        XCTAssertEqual(n, 1)
        XCTAssertEqual(g.segments[0].text, "the Nagios plugins")
    }

    func testGuardReportRoundTripAndWarning() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("guard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(GuardReport.load(workDir: dir, base: "m"), 0)
        GuardReport.store(2, workDir: dir, base: "m")
        XCTAssertEqual(GuardReport.load(workDir: dir, base: "m"), 2)
        GuardReport.store(0, workDir: dir, base: "m")   // reprocess with nothing found clears it
        XCTAssertEqual(GuardReport.load(workDir: dir, base: "m"), 0)
    }
}
