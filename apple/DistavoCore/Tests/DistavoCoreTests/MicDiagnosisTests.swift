import XCTest
@testable import DistavoCore

/// Picks the "microphone is silent" message from what is known (Vikunja #3930). Pure.
final class MicDiagnosisTests: XCTestCase {
    func testDeniedPermissionOffersSettings() {
        let d = MicDiagnosis.diagnose(permission: .denied, inputName: "MacBook Pro Microphone", inputMuted: false)
        XCTAssertEqual(d.cause, .permissionDenied)
        XCTAssertTrue(d.actions.contains(.openMicrophoneSettings))
    }

    func testMutedInputNamesTheDevice() {
        let d = MicDiagnosis.diagnose(permission: .granted, inputName: "Boya Mic", inputMuted: true)
        XCTAssertEqual(d.cause, .inputMuted)
        XCTAssertTrue(d.message.contains("Boya Mic"))
    }

    func testNoInputDevice() {
        let d = MicDiagnosis.diagnose(permission: .granted, inputName: nil, inputMuted: false)
        XCTAssertEqual(d.cause, .noInputDevice)
        XCTAssertTrue(d.actions.contains(.switchInput))
    }

    func testUnknownCauseStillShowsDeviceAndAlwaysOffersIgnore() {
        let d = MicDiagnosis.diagnose(permission: .granted, inputName: "USB Audio", inputMuted: false)
        XCTAssertEqual(d.cause, .unknown)
        XCTAssertTrue(d.message.contains("USB Audio"))
        XCTAssertTrue(d.actions.contains(.switchInput))
        for p in [MicDiagnosis.Permission.denied, .granted, .undetermined] {
            XCTAssertTrue(MicDiagnosis.diagnose(permission: p, inputName: nil, inputMuted: false).actions.contains(.ignore))
        }
    }

    func testBlankDeviceNameIsTreatedAsNone() {
        XCTAssertEqual(MicDiagnosis.diagnose(permission: .granted, inputName: "  ", inputMuted: false).cause, .noInputDevice)
    }
}
