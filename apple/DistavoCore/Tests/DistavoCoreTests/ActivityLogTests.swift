import XCTest
@testable import DistavoCore

final class ActivityLogTests: XCTestCase {

    private func tempLog() -> URL {
        TestTemp.root
            .appendingPathComponent("distavo-log-\(UUID().uuidString)")
            .appendingPathComponent("distavo.log")
    }

    func testLineHasTimestampAndMessage() {
        let log = ActivityLog(url: tempLog())
        let date = Date(timeIntervalSince1970: 1_782_460_272)  // fixed for determinism
        let line = log.line("Processing demo.wav", at: date)
        XCTAssertTrue(line.hasSuffix("Processing demo.wav"))
        XCTAssertTrue(line.range(of: #"^\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\] "#,
                                 options: .regularExpression) != nil,
                      "expected a [YYYY-MM-DD HH:MM:SS] prefix, got: \(line)")
    }

    func testAppendAndRecent() {
        let url = tempLog()
        let log = ActivityLog(url: url)
        let d = Date(timeIntervalSince1970: 1_782_460_272)
        log.append("Distavo started", at: d)
        log.append("Saved note: demo", at: d.addingTimeInterval(60))
        let recent = log.recent(10)
        XCTAssertEqual(recent.count, 2)
        XCTAssertTrue(recent[0].contains("Distavo started"))
        XCTAssertTrue(recent[1].contains("Saved note: demo"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testRecentTruncatesToCount() {
        let log = ActivityLog(url: tempLog())
        for i in 1...10 { log.append("event \(i)") }
        let recent = log.recent(3)
        XCTAssertEqual(recent.count, 3)
        XCTAssertTrue(recent.last!.contains("event 10"))
    }
}
