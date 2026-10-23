import XCTest
@testable import DistavoCore

/// #4012: a speakers.json beside a dropped file is honoured; the work-dir answer wins.
final class SpeakerHintsSidecarTests: XCTestCase {
    private func tmp() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("sh-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    func testSidecarBesideDroppedFileIsRead() throws {
        let dir = try tmp(), work = try tmp()
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: work) }
        try Data(#"{"count":2,"participants":"Anna (interviewer)"}"#.utf8)
            .write(to: dir.appendingPathComponent("interview-22-10-2026-10.00.speakers.json"))
        let src = dir.appendingPathComponent("interview-22-10-2026-10.00.mp4")
        let h = SpeakerHints.load(workDir: work, base: "interview-22-10-2026-10.00", source: src)
        XCTAssertEqual(h?.count, 2)
        XCTAssertEqual(h?.participants, "Anna (interviewer)")
    }
    func testWorkDirAnswerWinsOverBesideFile() throws {
        let dir = try tmp(), work = try tmp()
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: work) }
        try Data(#"{"count":5}"#.utf8).write(to: dir.appendingPathComponent("a.speakers.json"))
        try SpeakerHints(count: 3).save(workDir: work, base: "a")
        XCTAssertEqual(SpeakerHints.load(workDir: work, base: "a", source: dir.appendingPathComponent("a.m4a"))?.count, 3)
    }
    func testNoFileOrEmptyFileGivesNil() throws {
        let dir = try tmp(), work = try tmp()
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: work) }
        let src = dir.appendingPathComponent("b.m4a")
        XCTAssertNil(SpeakerHints.load(workDir: work, base: "b", source: src))
        try Data("{}".utf8).write(to: dir.appendingPathComponent("b.speakers.json"))
        XCTAssertNil(SpeakerHints.load(workDir: work, base: "b", source: src))
    }
}
