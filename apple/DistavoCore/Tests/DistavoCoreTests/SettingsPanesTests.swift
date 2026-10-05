import XCTest
@testable import DistavoCore

/// Pane visibility per edition, sidebar search and remembered-selection resolution
/// (Vikunja #2957).
final class SettingsPanesTests: XCTestCase {
    func testUpdatesPaneOnlyWhereUpdaterExists() {
        XCTAssertTrue(SettingsPane.visible(hasUpdates: true).contains(.updates))
        XCTAssertFalse(SettingsPane.visible(hasUpdates: false).contains(.updates))
    }

    func testOtherPanesAlwaysVisibleAndOrdered() {
        let expected: [SettingsPane] = [.general, .recording, .transcription, .notes, .summaries, .connections, .about]
        XCTAssertEqual(SettingsPane.visible(hasUpdates: false), expected)
        XCTAssertEqual(SettingsPane.visible(hasUpdates: true).last, .about)
    }

    func testEveryPaneHasTitleSymbolAndKeywords() {
        for p in SettingsPane.allCases {
            XCTAssertFalse(p.title.isEmpty)
            XCTAssertFalse(p.symbolName.isEmpty)
            XCTAssertFalse(p.keywords.isEmpty, "\(p) has no search keywords")
        }
    }

    func testBlankQueryKeepsAll() {
        let all = SettingsPane.visible(hasUpdates: true)
        XCTAssertEqual(SettingsPane.filter(all, query: "  "), all)
    }

    func testSearchFindsByTitleKeywordAndFoldsCase() {
        let all = SettingsPane.visible(hasUpdates: true)
        XCTAssertTrue(SettingsPane.filter(all, query: "NOTES").contains(.notes))
        XCTAssertTrue(SettingsPane.filter(all, query: "ollama").contains(.summaries))
        XCTAssertEqual(SettingsPane.filter(all, query: "note owner"), [.notes])
        XCTAssertTrue(SettingsPane.filter(all, query: "catalan").contains(.transcription))
        XCTAssertTrue(SettingsPane.filter(all, query: "zzzz").isEmpty)
    }

    func testSearchNeverResurrectsHiddenPane() {
        let noUpdates = SettingsPane.visible(hasUpdates: false)
        XCTAssertTrue(SettingsPane.filter(noUpdates, query: "sparkle").isEmpty)
    }

    func testResolveRememberedPane() {
        let v = SettingsPane.visible(hasUpdates: false)
        XCTAssertEqual(SettingsPane.resolve(stored: "notes", among: v), .notes)
        XCTAssertEqual(SettingsPane.resolve(stored: "updates", among: v), .general, "hidden pane falls back")
        XCTAssertEqual(SettingsPane.resolve(stored: "bogus", among: v), .general)
        XCTAssertEqual(SettingsPane.resolve(stored: nil, among: v), .general)
    }
}
