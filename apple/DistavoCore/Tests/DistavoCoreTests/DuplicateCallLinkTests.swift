import XCTest
@testable import DistavoCore

/// Vikunja #4014 wiring. Synthetic bases, times and participant names only.
final class DuplicateCallLinkTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    var dir: URL!
    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("dcl-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func testPhoneFileWithEndTimeReusesTheMacSheetAndBothAreLinked() throws {
        let mac = CallRecord(base: "Meeting_x", time: t0, durationSeconds: 2400, isLiveCapture: true)
        try SpeakerHints(count: 2, participants: "Alex (me), Sam", terms: ["Zeta"]).save(workDir: dir, base: "Meeting_x")
        XCTAssertNil(DuplicateCallLink.register(mac, workDir: dir), "first recording has no twin")
        // Android reports the END: start + 9 s late + 41 min.
        let phone = CallRecord(base: "phone-x", time: t0.addingTimeInterval(9 + 2460), durationSeconds: 2460, isLiveCapture: false)
        let link = DuplicateCallLink.register(phone, workDir: dir)
        XCTAssertEqual(link, AlsoCaptured(otherBase: "Meeting_x", isPrimary: false))
        XCTAssertEqual(SpeakerHints.load(workDir: dir, base: "phone-x")?.participants, "Alex (me), Sam")
        XCTAssertEqual(DuplicateCallLink.loadLink(workDir: dir, base: "Meeting_x"),
                       AlsoCaptured(otherBase: "phone-x", isPrimary: true))
    }

    func testStartTimeReadingAlsoMatches() {
        _ = DuplicateCallLink.register(CallRecord(base: "a", time: t0, durationSeconds: 1800, isLiveCapture: true), workDir: dir)
        let l = DuplicateCallLink.register(
            CallRecord(base: "b", time: t0.addingTimeInterval(20), durationSeconds: 1790, isLiveCapture: false), workDir: dir)
        XCTAssertEqual(l?.otherBase, "a")
    }

    func testAnExistingSheetIsNeverOverwritten() throws {
        try SpeakerHints(participants: "Mac names").save(workDir: dir, base: "m")
        try SpeakerHints(participants: "Own names").save(workDir: dir, base: "p")
        _ = DuplicateCallLink.register(CallRecord(base: "m", time: t0, durationSeconds: 600, isLiveCapture: true), workDir: dir)
        _ = DuplicateCallLink.register(CallRecord(base: "p", time: t0, durationSeconds: 600, isLiveCapture: true), workDir: dir)
        XCTAssertEqual(SpeakerHints.load(workDir: dir, base: "p")?.participants, "Own names")
    }

    func testBackToBackCallsAreNotLinked() {
        _ = DuplicateCallLink.register(CallRecord(base: "a", time: t0, durationSeconds: 1800, isLiveCapture: true), workDir: dir)
        XCTAssertNil(DuplicateCallLink.register(
            CallRecord(base: "b", time: t0.addingTimeInterval(1900), durationSeconds: 1800, isLiveCapture: true), workDir: dir))
        XCTAssertNil(DuplicateCallLink.loadLink(workDir: dir, base: "a"))
    }

    func testRecordRoundTrip() throws {
        let r = CallRecord(base: "r", time: t0, durationSeconds: 5, isLiveCapture: false)
        try DuplicateCallLink.saveRecord(r, workDir: dir)
        XCTAssertEqual(DuplicateCallLink.loadRecord(workDir: dir, base: "r"), r)
    }
}
