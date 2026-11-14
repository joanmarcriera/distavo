import XCTest
@testable import DistavoCore

/// Vikunja #6670: the Recording pane shows how big the recordings folder is and how much disk is left.
///
/// Expected strings are built with a `ByteCountFormatter` made here, never typed as literals, so the
/// suite does not depend on the machine's locale.
final class RecordingStorageTests: XCTestCase {
    private var tmp: URL!
    /// APFS allocation unit; sizes below are multiples of it so allocated size == logical size.
    private let block = 4096

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("recstorage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        // a test may have left a folder unreadable
        for sub in ["locked"] {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: tmp.appendingPathComponent(sub).path)
        }
        try? FileManager.default.removeItem(at: tmp)
    }

    private func write(_ bytes: Int, _ rel: String) throws {
        let url = tmp.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
    }

    private func decimal(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .decimal
        f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return f.string(fromByteCount: bytes)
    }

    // MARK: folder size

    func testFolderSizeSumsRegularFilesIncludingSubfolders() throws {
        try write(block, "a.wav")
        try write(2 * block, "Team/b.wav")
        try write(3 * block, "Team/Deep/c.m4a")
        XCTAssertEqual(RecordingStorage.folderSize(at: tmp), .init(bytes: Int64(6 * block), isLowerBound: false))
    }

    func testFolderSizeCountsHiddenFiles() throws {
        try write(block, ".hidden.wav")
        XCTAssertEqual(RecordingStorage.folderSize(at: tmp)?.bytes, Int64(block))
    }

    func testEmptyFolderIsZero() {
        XCTAssertEqual(RecordingStorage.folderSize(at: tmp)?.bytes, 0)
    }

    func testSparseFileCountsWhatItOccupiesNotItsLogicalSize() throws {
        // A cloud placeholder or sparse file reports a big logical size but holds almost nothing on disk.
        let url = tmp.appendingPathComponent("placeholder.wav")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let h = try FileHandle(forWritingTo: url)
        try h.truncate(atOffset: 50_000_000)
        try h.close()
        let size = try XCTUnwrap(RecordingStorage.folderSize(at: tmp)).bytes
        XCTAssertLessThan(size, 1_000_000, "allocated size, not the 50 MB logical size")
    }

    func testRootSymlinkIsResolved() throws {
        try write(2 * block, "real/a.wav")
        let link = tmp.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: tmp.appendingPathComponent("real"))
        XCTAssertEqual(RecordingStorage.folderSize(at: link)?.bytes, Int64(2 * block))
    }

    func testSymlinksInsideAreNotFollowed() throws {
        try write(block, "real/a.wav")
        try write(block, "other/b.wav")
        try FileManager.default.createSymbolicLink(at: tmp.appendingPathComponent("real/loop"),
                                                   withDestinationURL: tmp.appendingPathComponent("other"))
        XCTAssertEqual(RecordingStorage.folderSize(at: tmp.appendingPathComponent("real"))?.bytes, Int64(block))
    }

    // MARK: missing vs unreadable

    func testMissingFolderUnderReadableParentIsZero() {
        XCTAssertEqual(RecordingStorage.folderSize(at: tmp.appendingPathComponent("nope"))?.bytes, 0)
        XCTAssertEqual(RecordingStorage.folderSize(at: tmp.appendingPathComponent("not/yet/created"))?.bytes, 0)
    }

    func testPlainFileIsNotAFolder() throws {
        try write(10, "f.wav")
        XCTAssertNil(RecordingStorage.folderSize(at: tmp.appendingPathComponent("f.wav")),
                     "not a folder we can list: unknown, never a made-up size")
    }

    func testUnreadableFolderIsUnknown() throws {
        try XCTSkipIf(getuid() == 0, "root can read anything")
        try write(10, "locked/x.wav")
        let locked = tmp.appendingPathComponent("locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        XCTAssertNil(RecordingStorage.folderSize(at: locked))
    }

    func testMissingFolderUnderUnreadableParentIsUnknownNotZero() throws {
        // What a sandboxed app sees for a folder it has no access to: it cannot tell "missing" from "denied".
        try XCTSkipIf(getuid() == 0, "root can read anything")
        try write(10, "locked/x.wav")
        let locked = tmp.appendingPathComponent("locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        XCTAssertNil(RecordingStorage.folderSize(at: locked.appendingPathComponent("Recordings")))
    }

    // MARK: cancellation and the entry cap

    func testCancelledScanReturnsNil() throws {
        for i in 0..<5 { try write(block, "f\(i).wav") }
        XCTAssertNil(RecordingStorage.folderSize(at: tmp, isCancelled: { true }))
    }

    func testCancellationIsCheckedWhileWalking() throws {
        for i in 0..<20 { try write(block, "f\(i).wav") }
        var polls = 0
        let result = RecordingStorage.folderSize(at: tmp, isCancelled: { polls += 1; return polls > 3 })
        XCTAssertNil(result)
        XCTAssertLessThan(polls, 10, "stops soon after cancellation, does not finish the walk")
    }

    func testEntryCapGivesALowerBound() throws {
        for i in 0..<10 { try write(block, "f\(i).wav") }
        let capped = try XCTUnwrap(RecordingStorage.folderSize(at: tmp, maxEntries: 4))
        XCTAssertTrue(capped.isLowerBound)
        XCTAssertGreaterThan(capped.bytes, 0)
        XCTAssertLessThan(capped.bytes, Int64(10 * block))
        let full = try XCTUnwrap(RecordingStorage.folderSize(at: tmp, maxEntries: 10))
        XCTAssertFalse(full.isLowerBound, "exactly at the cap is still complete")
        XCTAssertEqual(full.bytes, Int64(10 * block))
    }

    // MARK: free space

    func testFreeBytesOnExistingFolderIsPositive() throws {
        XCTAssertGreaterThan(try XCTUnwrap(RecordingStorage.freeBytes(at: tmp)), 0)
    }

    func testFreeBytesWalksUpFromAMissingFolder() throws {
        XCTAssertGreaterThan(try XCTUnwrap(RecordingStorage.freeBytes(at: tmp.appendingPathComponent("not/yet/created"))), 0)
    }

    func testFullDiskIsARealZeroNotUnknown() {
        // 0 free is shown as 0 and triggers the caption; only nil means "could not read".
        XCTAssertEqual(RecordingStorage.summary(folder: .init(bytes: 0, isLowerBound: false), freeBytes: 0),
                       "Recordings folder: \(decimal(0)) · \(decimal(0)) free on this disk")
        XCTAssertNotNil(RecordingStorage.lowSpaceCaption(freeBytes: 0, format: .full))
        XCTAssertTrue(RecordingStorage.isLowOnSpace(freeBytes: 0))
    }

    // MARK: text

    func testLowSpaceThresholdIs25GB() {
        XCTAssertEqual(RecordingStorage.lowSpaceBytes, 25_000_000_000)
        XCTAssertTrue(RecordingStorage.isLowOnSpace(freeBytes: 24_999_999_999))
        XCTAssertFalse(RecordingStorage.isLowOnSpace(freeBytes: 25_000_000_000))
    }

    func testSummaryLine() {
        XCTAssertEqual(RecordingStorage.summary(folder: .init(bytes: 7_100_000_000, isLowerBound: false), freeBytes: 18_000_000_000),
                       "Recordings folder: \(decimal(7_100_000_000)) · \(decimal(18_000_000_000)) free on this disk")
        XCTAssertEqual(RecordingStorage.summary(folder: nil, freeBytes: 18_000_000_000),
                       "Recordings folder: size unknown · \(decimal(18_000_000_000)) free on this disk")
        XCTAssertEqual(RecordingStorage.summary(folder: .init(bytes: 5_000_000, isLowerBound: false), freeBytes: nil),
                       "Recordings folder: \(decimal(5_000_000)) · free space unknown")
        XCTAssertEqual(RecordingStorage.summary(folder: .init(bytes: 9_000_000_000, isLowerBound: true), freeBytes: 18_000_000_000),
                       "Recordings folder: at least \(decimal(9_000_000_000)) · \(decimal(18_000_000_000)) free on this disk")
    }

    func testCaptionNamesBothFormatsUnderFullAndOnlyCompactUnderCompact() throws {
        let full = try XCTUnwrap(RecordingStorage.lowSpaceCaption(freeBytes: 1_000_000_000, format: .full))
        XCTAssertEqual(full, "Less than 25 GB free: a one-hour recording takes about 1.4 GB (0.7 GB compact).")
        let compact = try XCTUnwrap(RecordingStorage.lowSpaceCaption(freeBytes: 1_000_000_000, format: .int16))
        XCTAssertEqual(compact, "Less than 25 GB free: a one-hour recording takes about 0.7 GB.")
        XCTAssertFalse(compact.contains("1.4"))
    }

    func testNoCaptionWhenThereIsRoomOrFreeSpaceIsUnknown() {
        XCTAssertNil(RecordingStorage.lowSpaceCaption(freeBytes: 25_000_000_000, format: .full))
        XCTAssertNil(RecordingStorage.lowSpaceCaption(freeBytes: nil, format: .full))
    }

    func testGBFiguresComeFromBytesPerHour() {
        // Independent of the helper: 48 kHz x 2 channels x bytes per sample x 3600 s, in decimal GB.
        func gb(_ f: RecordingStorageFormat) -> String {
            String(format: "%.1f", Double(48_000 * 2 * (f.bitDepth / 8) * 3600) / 1e9)
        }
        XCTAssertEqual(RecordingStorageFormat.full.displayName, "Full quality (32-bit, about \(gb(.full)) GB per hour)")
        XCTAssertEqual(RecordingStorageFormat.int16.displayName, "Compact (16-bit, about \(gb(.int16)) GB per hour)")
        XCTAssertEqual(RecordingStorageFormat.full.gbPerHourLabel, gb(.full))
        XCTAssertEqual(RecordingStorageFormat.int16.gbPerHourLabel, gb(.int16))
        XCTAssertEqual(RecordingStorageFormat.full.gbPerHourLabel, "1.4")
        XCTAssertEqual(RecordingStorageFormat.int16.gbPerHourLabel, "0.7")
    }
}
