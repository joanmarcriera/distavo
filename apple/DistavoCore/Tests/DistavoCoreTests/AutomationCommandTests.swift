import XCTest
@testable import DistavoCore

/// #2953: URL parser (incl. hostile input) and queued-file naming.
final class AutomationCommandTests: XCTestCase {

    func testKnownCommands() {
        XCTAssertEqual(AutomationCommand.parse("distavo://open-latest-note"), .openLatestNote)
        XCTAssertEqual(AutomationCommand.parse("distavo://process-now"), .processNow)
        XCTAssertEqual(AutomationCommand.parse("distavo://settings"), .settings)
        XCTAssertEqual(AutomationCommand.parse("distavo://notes"), .notes)
        XCTAssertNil(AutomationCommand.parse("distavo://notes/Meeting_2026"), "a note cannot be named by link")
        XCTAssertEqual(AutomationCommand.parse("distavo://record/start"), .recordStart)
        XCTAssertEqual(AutomationCommand.parse("distavo://record/stop"), .recordStop)
        XCTAssertEqual(AutomationCommand.parse(URL(string: "DISTAVO://Record/Stop/")!), .recordStop)
    }

    func testOnlyRecordStartNeedsConfirmation() {
        XCTAssertTrue(AutomationCommand.recordStart.requiresConfirmation)
        for c in [AutomationCommand.openLatestNote, .processNow, .settings, .notes, .recordStop] {
            XCTAssertFalse(c.requiresConfirmation)
        }
    }

    func testQueryAndFragmentAreIgnoredNotInterpreted() {
        XCTAssertEqual(AutomationCommand.parse("distavo://process-now?path=/etc/passwd#x"), .processNow)
        XCTAssertEqual(AutomationCommand.parse("distavo://settings?delete=all"), .settings)
    }

    func testHostileInputIsRejected() {
        let hostile = [
            "", "distavo:", "distavo://", "distavo:///record/start",
            "http://record/start", "file:///etc/passwd", "distavo://transcribe?path=/etc/passwd",
            "distavo://transcribe?bookmark=abc", "distavo://record", "distavo://record/",
            "distavo://record/start/extra", "distavo://record//start",
            "distavo://../../etc/passwd", "distavo://record/../start", "distavo://record/%2e%2e/start",
            "distavo://record%2Fstart", "distavo://%72ecord/start", "distavo://settings/../process-now",
            "distavo://user:pw@settings", "distavo://settings:80", "distavo://unknown",
            "distavo://record/start\n", "distavo://process-now\u{0}", "not a url",
            "distavo://open-latest-note%00", "distavo://delete-all", "distavo://quit",
        ]
        for s in hostile { XCTAssertNil(AutomationCommand.parse(s), "should reject: \(s.debugDescription)") }
    }

    func testExtraParserCases() {
        XCTAssertNil(AutomationCommand.parse("distavo:record/start"))
        XCTAssertEqual(AutomationCommand.parse("distavo://Record/Start"), .recordStart)
        XCTAssertEqual(AutomationCommand.parse("distavo://record/start/"), .recordStart)
        XCTAssertEqual(QueuedFile.sanitizedName(".wav"), "wav")
        XCTAssertFalse(QueuedFile.isSupportedMedia(QueuedFile.sanitizedName(".wav")))
    }

    func testTempNameIsInvisibleToScannerAndRecorderRecovery() {
        let dest = URL(fileURLWithPath: "/r/talk.wav")
        let tmp = QueuedFile.tempURL(for: dest)
        XCTAssertEqual(tmp.lastPathComponent, ".talk.wav.distavo-copy")
        XCTAssertTrue(QueuedFile.isTempName(tmp.lastPathComponent))
        XCTAssertFalse(QueuedFile.isSupportedMedia(tmp.lastPathComponent))
        // MeetingRecorder.recoverOrphanedRecordings matches hasSuffix(".wav.part").
        XCTAssertFalse(tmp.lastPathComponent.hasSuffix(".wav.part"))
        XCTAssertFalse(QueuedFile.isTempName("talk.wav"))
        XCTAssertFalse(QueuedFile.isTempName(".hidden.wav"))
    }

    func testRemoveStaleTemps() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for n in [".a.wav.distavo-copy", "keep.wav", "x.wav.part"] {
            try Data([1]).write(to: dir.appendingPathComponent(n))
        }
        XCTAssertEqual(QueuedFile.removeStaleTemps(in: dir), 1)
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
        XCTAssertEqual(left, ["keep.wav", "x.wav.part"])
    }

    func testSourceProblemAndInsideFolder() {
        XCTAssertNil(QueuedFile.sourceProblem(isRegularFile: true, size: 10))
        XCTAssertEqual(QueuedFile.sourceProblem(isRegularFile: false, size: 10), .notRegularFile)
        XCTAssertEqual(QueuedFile.sourceProblem(isRegularFile: true, size: 0), .empty)
        XCTAssertEqual(QueuedFile.sourceProblem(isRegularFile: true, size: nil), .empty)
        let r = URL(fileURLWithPath: "/tmp/rec")
        XCTAssertTrue(QueuedFile.isInside(URL(fileURLWithPath: "/tmp/rec/sub/a.wav"), folder: r))
        XCTAssertFalse(QueuedFile.isInside(URL(fileURLWithPath: "/tmp/rec"), folder: r))
        XCTAssertFalse(QueuedFile.isInside(URL(fileURLWithPath: "/tmp/rec2/a.wav"), folder: r))
        XCTAssertFalse(QueuedFile.isInside(URL(fileURLWithPath: "/tmp/rec/../x.wav"), folder: r))
    }

    func testThrottle() {
        var t = CommandThrottle(interval: 5)
        XCTAssertTrue(t.allow(.processNow, now: 100))
        XCTAssertFalse(t.allow(.processNow, now: 102))
        XCTAssertTrue(t.allow(.settings, now: 102))
        XCTAssertTrue(t.allow(.processNow, now: 105.5))
    }

    func testHugeStringsAreRejected() {
        XCTAssertNil(AutomationCommand.parse("distavo://process-now?" + String(repeating: "a", count: 100_000)))
        XCTAssertNil(AutomationCommand.parse("distavo://" + String(repeating: "a", count: 10_000)))
    }

    func testSupportedMedia() {
        XCTAssertTrue(QueuedFile.isSupportedMedia("memo.M4A"))
        XCTAssertTrue(QueuedFile.isSupportedMedia("a.b.mp4"))
        XCTAssertFalse(QueuedFile.isSupportedMedia("notes.pdf"))
        XCTAssertFalse(QueuedFile.isSupportedMedia("m4a"))
        XCTAssertFalse(QueuedFile.isSupportedMedia(".m4a"))
    }

    func testSanitizedNameStripsTraversalAndHidden() {
        XCTAssertEqual(QueuedFile.sanitizedName("../../etc/x.wav"), "x.wav")
        XCTAssertEqual(QueuedFile.sanitizedName(".hidden.wav"), "hidden.wav")
        XCTAssertEqual(QueuedFile.sanitizedName(".."), "recording")
        XCTAssertEqual(QueuedFile.sanitizedName(""), "recording")
        XCTAssertEqual(QueuedFile.sanitizedName("a\u{0}b.wav"), "ab.wav")
        XCTAssertLessThanOrEqual(QueuedFile.sanitizedName(String(repeating: "x", count: 500) + ".wav").count, 106)
    }

    func testUniqueDestinationNeverOverwrites() {
        let dir = URL(fileURLWithPath: "/r")
        var taken: Set<String> = []
        let exists: (URL) -> Bool = { taken.contains($0.lastPathComponent) }
        XCTAssertEqual(QueuedFile.uniqueDestination(forName: "a.m4a", in: dir, exists: exists).lastPathComponent, "a.m4a")
        taken = ["a.m4a"]
        XCTAssertEqual(QueuedFile.uniqueDestination(forName: "a.m4a", in: dir, exists: exists).lastPathComponent, "a 2.m4a")
        taken = ["a.m4a", "a 2.m4a"]
        XCTAssertEqual(QueuedFile.uniqueDestination(forName: "a.m4a", in: dir, exists: exists).lastPathComponent, "a 3.m4a")
        let t = QueuedFile.uniqueDestination(forName: "../../x.wav", in: dir, exists: { _ in false })
        XCTAssertEqual(t.deletingLastPathComponent().path, "/r")
    }
}
