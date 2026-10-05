import XCTest
@testable import DistavoCore

/// #2953: URL parser (incl. hostile input) and queued-file naming.
final class AutomationCommandTests: XCTestCase {

    func testKnownCommands() {
        XCTAssertEqual(AutomationCommand.parse("distavo://open-latest-note"), .openLatestNote)
        XCTAssertEqual(AutomationCommand.parse("distavo://process-now"), .processNow)
        XCTAssertEqual(AutomationCommand.parse("distavo://settings"), .settings)
        XCTAssertEqual(AutomationCommand.parse("distavo://record/start"), .recordStart)
        XCTAssertEqual(AutomationCommand.parse("distavo://record/stop"), .recordStop)
        XCTAssertEqual(AutomationCommand.parse(URL(string: "DISTAVO://Record/Stop/")!), .recordStop)
    }

    func testOnlyRecordStartNeedsConfirmation() {
        XCTAssertTrue(AutomationCommand.recordStart.requiresConfirmation)
        for c in [AutomationCommand.openLatestNote, .processNow, .settings, .recordStop] {
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
