// RecordingOptionsConfigTests - migration/default rules for the `recording` object (Vikunja #2950).
import XCTest
@testable import DistavoCore

final class RecordingOptionsConfigTests: XCTestCase {
    private func decode(_ json: String) throws -> Config {
        try JSONDecoder().decode(Config.self, from: Data(json.utf8))
    }

    func testConfigPredatingTheKeyDecodesToOffAndDefaults() throws {
        let o = try decode("{}").recording
        XCTAssertFalse(o.bookmarkHotkeyEnabled)
        XCTAssertEqual(o.bookmarkHotkey, .default)
        XCTAssertEqual(o.bookmarkHotkey.displayName, "⌃⌥⌘M")
        XCTAssertEqual(o.clipLeadSeconds, 15)
        XCTAssertEqual(o.clipTailSeconds, 30)
        XCTAssertEqual(o, RecordingOptions())
        XCTAssertFalse(Config.recommendedForThisMac().recording.bookmarkHotkeyEnabled, "off on fresh installs too")
    }

    func testPartialWrongTypedAndInvalidValuesFallBack() throws {
        let partial = try decode(#"{"recording":{"bookmark_hotkey_enabled":true,"clip_lead_seconds":5}}"#).recording
        XCTAssertTrue(partial.bookmarkHotkeyEnabled)
        XCTAssertEqual(partial.clipLeadSeconds, 5)
        XCTAssertEqual(partial.clipTailSeconds, 30)
        let bad = try decode(#"{"recording":{"bookmark_hotkey_enabled":"yes","bookmark_hotkey":3,"clip_lead_seconds":"x"}}"#).recording
        XCTAssertEqual(bad, RecordingOptions())
        // A hotkey with no command/option/control modifier would steal typing: rejected.
        let plain = try decode(#"{"recording":{"bookmark_hotkey":{"key_code":46,"modifiers":0}}}"#).recording
        XCTAssertEqual(plain.bookmarkHotkey, .default)
        let notObject = try decode(#"{"recording":7,"min_recording_seconds":42}"#)
        XCTAssertEqual(notObject.recording, RecordingOptions())
        XCTAssertEqual(notObject.minRecordingSeconds, 42)
    }

    func testClampingAndRoundTrip() throws {
        XCTAssertEqual(try decode(#"{"recording":{"clip_lead_seconds":-4}}"#).recording.clipLeadSeconds, 0)
        XCTAssertEqual(try decode(#"{"recording":{"clip_tail_seconds":99999}}"#).recording.clipTailSeconds, 600)
        var cfg = Config()
        cfg.recording = RecordingOptions(bookmarkHotkeyEnabled: true,
                                         bookmarkHotkey: HotkeySpec(keyCode: 40, modifiers: HotkeySpec.control | HotkeySpec.shift),
                                         clipLeadSeconds: 20, clipTailSeconds: 45)
        let back = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(cfg))
        XCTAssertEqual(back.recording, cfg.recording)
        XCTAssertEqual(back.recording.bookmarkHotkey.displayName, "⌃⇧K")
    }

    func testHotkeyValidity() {
        XCTAssertTrue(HotkeySpec.default.isValid)
        XCTAssertFalse(HotkeySpec(keyCode: 46, modifiers: HotkeySpec.shift).isValid)
        XCTAssertFalse(HotkeySpec(keyCode: 500, modifiers: HotkeySpec.cmd).isValid)
        XCTAssertFalse(HotkeySpec(keyCode: 46, modifiers: HotkeySpec.cmd | 1).isValid)
    }
}
