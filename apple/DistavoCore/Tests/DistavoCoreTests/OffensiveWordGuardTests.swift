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
    /// Wider monitoring vocabulary (#3951): more words after, and a sibling tool right before or after.
    func testWiderToolContextBecomesNagios() {
        for tail in ["plugin", "checks", "core", "and Icinga", "or CheckMK", "XI"] {
            let r = OffensiveWordGuard.apply("we ran \(slur) \(tail) there")
            XCTAssertEqual(r.text, "we ran Nagios \(tail) there", tail)
            XCTAssertEqual(r.flagged, 1, tail)
        }
        for head in ["Icinga and", "Zabbix or", "CheckMK,", "Checkmk vs"] {
            let r = OffensiveWordGuard.apply("we compared \(head) \(slur) yesterday")
            XCTAssertEqual(r.text, "we compared \(head) Nagios yesterday", head)
        }
    }
    /// A sentence or line break, or a generic English word, must never turn a slur into "Nagios".
    func testContextDoesNotCrossBreaksOrGenericWords() {
        for text in ["a \(slur). Config is", "\(slur)\n\nHost of the show", "\(slur) based on race",
                     "\(slur) style", "\(slur). Core values", "Zabbix. \(slur) x", "Prometheus \(slur)"] {
            let r = OffensiveWordGuard.apply(text)
            XCTAssertFalse(r.text.contains("Nagios"), text)
            XCTAssertTrue(r.text.contains(OffensiveWordGuard.placeholder), text)
        }
    }
    /// Open low #10 of the j review: hyphen and slash forms are tool context too.
    func testHyphenAndSlashFormsBecomeNagios() {
        let cases = [("the \(slur)s-plugins dir", "the Nagios-plugins dir"),
                     ("\(slur)/Icinga checks", "Nagios/Icinga checks"),
                     ("Icinga/\(slur) setup", "Icinga/Nagios setup"),
                     ("\(slur) / Zabbix", "Nagios / Zabbix")]
        for (heard, want) in cases {
            let r = OffensiveWordGuard.apply(heard)
            XCTAssertEqual(r.text, want, heard)
            XCTAssertEqual(r.flagged, 1, heard)
        }
        // A hyphen or slash before a generic word is still no tool context.
        // A spaced dash is a spoken pause, not a compound (Sonnet review): "he said x - check this out".
        for text in ["\(slur)-style", "\(slur)/based", "Prometheus/\(slur)", "he said \(slur) - check this out"] {
            XCTAssertFalse(OffensiveWordGuard.apply(text).text.contains("Nagios"), text)
        }
    }
    func testNoContextStillRemoved() {
        let r = OffensiveWordGuard.apply("the \(slur) alone and then nothing about tools")
        XCTAssertTrue(r.text.contains(OffensiveWordGuard.placeholder))
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
