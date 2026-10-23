import XCTest
@testable import DistavoCore

final class PermissionNudgePolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testFirstNoticeMentionsPermission() {
        XCTAssertEqual(PermissionNudgePolicy.notice(stoppedBySilence: false, microphoneHeard: true, lastHint: nil, now: now),
                       .permissionHint)
    }
    func testRateLimitedToOncePerDay() {
        let recent = now.addingTimeInterval(-3600)
        XCTAssertEqual(PermissionNudgePolicy.notice(stoppedBySilence: false, microphoneHeard: true, lastHint: recent, now: now), .plain)
        let old = now.addingTimeInterval(-PermissionNudgePolicy.minimumInterval - 1)
        XCTAssertEqual(PermissionNudgePolicy.notice(stoppedBySilence: false, microphoneHeard: true, lastHint: old, now: now), .permissionHint)
    }
    func testSilenceStopAndDeadMicNeverBlamePermission() {
        XCTAssertEqual(PermissionNudgePolicy.notice(stoppedBySilence: true, microphoneHeard: true, lastHint: nil, now: now), .plain)
        XCTAssertEqual(PermissionNudgePolicy.notice(stoppedBySilence: false, microphoneHeard: false, lastHint: nil, now: now), .plain)
    }
    func testTextsDoNotPromiseToOpenSettings() {
        XCTAssertTrue(PermissionNudgePolicy.body(.permissionHint).contains("will not open"))
        XCTAssertFalse(PermissionNudgePolicy.body(.plain).contains("System Settings"))
    }
}
