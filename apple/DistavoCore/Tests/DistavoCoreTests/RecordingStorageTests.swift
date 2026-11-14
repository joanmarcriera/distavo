import XCTest
@testable import DistavoCore

/// Vikunja #6670: the Recording pane shows how big the recordings folder is and how much disk is left.
final class RecordingStorageTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("recstorage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private func write(_ bytes: Int, _ rel: String) throws {
        let url = tmp.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
    }

    func testFolderBytesSumsRegularFilesIncludingSubfolders() throws {
        try write(1000, "a.wav")
        try write(2500, "Team/b.wav")
        try write(500, "Team/Deep/c.m4a")
        XCTAssertEqual(RecordingStorage.folderBytes(at: tmp), 4000)
    }

    func testFolderBytesCountsHiddenFiles() throws {
        try write(300, ".hidden.wav")
        XCTAssertEqual(RecordingStorage.folderBytes(at: tmp), 300)
    }

    func testEmptyFolderIsZero() {
        XCTAssertEqual(RecordingStorage.folderBytes(at: tmp), 0)
    }

    func testMissingFolderIsZeroNotUnknown() {
        XCTAssertEqual(RecordingStorage.folderBytes(at: tmp.appendingPathComponent("nope")), 0)
    }

    func testPlainFileIsNotAFolder() throws {
        try write(10, "f.wav")
        XCTAssertNil(RecordingStorage.folderBytes(at: tmp.appendingPathComponent("f.wav")),
                     "not a folder we can list: unknown, never a made-up size")
    }

    func testUnreadableFolderIsUnknown() throws {
        try XCTSkipIf(getuid() == 0, "root can read anything")
        try write(10, "locked/x.wav")
        let locked = tmp.appendingPathComponent("locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        XCTAssertNil(RecordingStorage.folderBytes(at: locked))
    }

    func testFreeBytesOnExistingFolderIsPositive() {
        XCTAssertGreaterThan(RecordingStorage.freeBytes(at: tmp), 0)
    }

    func testFreeBytesWalksUpFromAMissingFolder() {
        let missing = tmp.appendingPathComponent("not/yet/created")
        XCTAssertGreaterThan(RecordingStorage.freeBytes(at: missing), 0)
    }

    func testLowSpaceThresholdIs25GB() {
        XCTAssertEqual(RecordingStorage.lowSpaceBytes, 25_000_000_000)
        XCTAssertTrue(RecordingStorage.isLowOnSpace(freeBytes: 24_999_999_999))
        XCTAssertFalse(RecordingStorage.isLowOnSpace(freeBytes: 25_000_000_000))
    }

    func testSummaryLine() {
        XCTAssertEqual(RecordingStorage.summary(folderBytes: 7_100_000_000, freeBytes: 18_000_000_000),
                       "Recordings folder: 7.1 GB · 18 GB free on this disk")
        XCTAssertEqual(RecordingStorage.summary(folderBytes: nil, freeBytes: 18_000_000_000),
                       "Recordings folder: size unknown · 18 GB free on this disk")
        XCTAssertEqual(RecordingStorage.summary(folderBytes: 5_000_000, freeBytes: nil),
                       "Recordings folder: 5 MB · free space unknown")
    }

    func testLowSpaceCaptionNamesBothFormats() {
        XCTAssertEqual(RecordingStorage.lowSpaceCaption,
                       "Less than 25 GB free: a one-hour recording takes about 1.4 GB (0.7 GB compact).")
    }

    func testPickerLabelsMatchTheSettingsWording() {
        XCTAssertEqual(RecordingStorageFormat.full.displayName, "Full quality (32-bit, about 1.4 GB per hour)")
        XCTAssertEqual(RecordingStorageFormat.int16.displayName, "Compact (16-bit, about 0.7 GB per hour)")
    }
}
