import XCTest
@testable import DistavoCore

final class WhisperLanguageCatalogTests: XCTestCase {

    func testAutoDetectIsFirstAndEmpty() {
        let first = WhisperLanguageCatalog.all.first
        XCTAssertEqual(first?.code, "")
        XCTAssertFalse(first?.englishName.isEmpty ?? true)
    }

    func testContainsMarcsLanguages() {
        let codes = Set(WhisperLanguageCatalog.all.map(\.code))
        XCTAssertTrue(codes.contains("ca"), "Catalan must be selectable")
        XCTAssertTrue(codes.contains("es"))
        XCTAssertTrue(codes.contains("en"))
    }

    func testCodesAreUnique() {
        let codes = WhisperLanguageCatalog.all.map(\.code)
        XCTAssertEqual(codes.count, Set(codes).count, "no duplicate/alias codes")
    }

    func testLanguagesSortedByEnglishNameAfterAutoDetect() {
        let names = WhisperLanguageCatalog.all.dropFirst().map(\.englishName)
        XCTAssertEqual(names, names.sorted(), "languages after Auto-detect are alphabetical")
    }

    func testHasFullWhisperSet() {
        // Whisper supports ~99 languages; Auto-detect makes it ~100. Guard against
        // a truncated list slipping in.
        XCTAssertGreaterThan(WhisperLanguageCatalog.all.count, 90)
    }
}
