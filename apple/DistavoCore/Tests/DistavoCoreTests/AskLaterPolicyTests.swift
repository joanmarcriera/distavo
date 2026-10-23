import XCTest
@testable import DistavoCore

final class AskLaterPolicyTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testWaitsThenRemindsAtDue() {
        let e = AskLaterPolicy.start(base: "a", choice: .minutes(15), now: t0)
        XCTAssertEqual(AskLaterPolicy.nextStep(e, now: t0.addingTimeInterval(14 * 60)), .wait)
        XCTAssertEqual(AskLaterPolicy.nextStep(e, now: t0.addingTimeInterval(15 * 60)), .remind)
    }

    func testRepeatsOnceThenGivesUp() {
        var e = AskLaterPolicy.start(base: "a", choice: .minutes(5), now: t0)
        var now = t0.addingTimeInterval(5 * 60)
        XCTAssertEqual(AskLaterPolicy.nextStep(e, now: now), .remind)
        e = AskLaterPolicy.reminded(e, now: now)
        XCTAssertEqual(AskLaterPolicy.nextStep(e, now: now), .wait)
        now = now.addingTimeInterval(AskLaterPolicy.repeatInterval)
        XCTAssertEqual(AskLaterPolicy.nextStep(e, now: now), .remind)
        e = AskLaterPolicy.reminded(e, now: now)
        XCTAssertEqual(AskLaterPolicy.nextStep(e, now: now.addingTimeInterval(86_400)), .leaveInMenu)
    }

    func testAfterNextCallWaitsUntilACallEnds() {
        var e = AskLaterPolicy.start(base: "a", choice: .afterNextCall, now: t0)
        XCTAssertEqual(AskLaterPolicy.nextStep(e, now: t0.addingTimeInterval(86_400)), .wait)
        e = AskLaterPolicy.nextCallEnded(e, now: t0.addingTimeInterval(3600))
        XCTAssertEqual(AskLaterPolicy.nextStep(e, now: t0.addingTimeInterval(3600)), .remind)
    }

    func testPersistsAcrossRelaunch() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("asklater-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let e = AskLaterPolicy.start(base: "Meeting_x", choice: .minutes(60), now: t0)
        try AskLaterPolicy.save(e, workDir: dir)
        XCTAssertEqual(AskLaterPolicy.load(workDir: dir, base: "Meeting_x"), e)
        AskLaterPolicy.remove(workDir: dir, base: "Meeting_x")
        XCTAssertNil(AskLaterPolicy.load(workDir: dir, base: "Meeting_x"))
    }
}
