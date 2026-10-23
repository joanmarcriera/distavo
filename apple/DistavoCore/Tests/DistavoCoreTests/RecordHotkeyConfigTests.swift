import XCTest
@testable import DistavoCore

/// Vikunja #4001: the record start/stop shortcut config and its clash check.
final class RecordHotkeyConfigTests: XCTestCase {
    func testOffAndDefaultForOldAndFreshConfigs() throws {
        let old = try JSONDecoder().decode(Config.self, from: Data("{}".utf8))
        XCTAssertFalse(old.recording.recordHotkeyEnabled)
        XCTAssertEqual(old.recording.recordHotkey, .recordDefault)
        XCTAssertEqual(HotkeySpec.recordDefault.displayName, "⌃⌥⌘R")
        let fresh = Config.recommendedForThisMac(embeddedSupported: false, memoryBytes: 16 << 30)
        XCTAssertFalse(fresh.recording.recordHotkeyEnabled, "inert until switched on, also for fresh installs")
    }

    func testRoundTripAndBadValuesFallBack() throws {
        var cfg = Config()
        cfg.recording.recordHotkeyEnabled = true
        cfg.recording.recordHotkey = HotkeySpec(keyCode: 1, modifiers: HotkeySpec.cmd | HotkeySpec.shift)
        let back = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(cfg))
        XCTAssertEqual(back.recording.recordHotkey, cfg.recording.recordHotkey)
        XCTAssertTrue(back.recording.recordHotkeyEnabled)
        let bad = try JSONDecoder().decode(Config.self, from: Data(#"{"recording":{"record_hotkey_enabled":"yes","record_hotkey":{"key_code":999,"modifiers":0}}}"#.utf8))
        XCTAssertFalse(bad.recording.recordHotkeyEnabled)
        XCTAssertEqual(bad.recording.recordHotkey, .recordDefault)
    }

    func testClashWithKeyMomentShortcut() {
        var o = RecordingOptions()
        XCTAssertNil(o.recordHotkeyProblem)                       // disabled: nothing to report
        o.recordHotkeyEnabled = true
        XCTAssertNil(o.recordHotkeyProblem)
        o.bookmarkHotkeyEnabled = true
        o.bookmarkHotkey = o.recordHotkey
        XCTAssertNotNil(o.recordHotkeyProblem)
        o.bookmarkHotkeyEnabled = false                           // a disabled key-moment shortcut does not clash
        XCTAssertNil(o.recordHotkeyProblem)
        o.bookmarkHotkeyEnabled = true
        o.bookmarkHotkey = .default
        XCTAssertNil(o.recordHotkeyProblem)                       // ⌃⌥⌘M vs ⌃⌥⌘R
    }
}
