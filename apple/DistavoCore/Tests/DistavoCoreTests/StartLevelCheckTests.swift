import XCTest
@testable import DistavoCore

final class StartLevelCheckTests: XCTestCase {
    func testSilentStartWarnsOnceAtTheWindow() {
        var c = StartLevelCheck(window: 5)
        let r = (0..<8).map { _ in c.ingest(mic: 0, system: 0.0001) }
        XCTAssertEqual(r, [false, false, false, false, true, false, false, false])
    }

    func testAnySoundEndsTheCheckQuietly() {
        var c = StartLevelCheck(window: 5)
        XCTAssertFalse(c.ingest(mic: 0, system: 0))
        XCTAssertFalse(c.ingest(mic: 0.05, system: 0))
        XCTAssertTrue((0..<10).allSatisfy { _ in !c.ingest(mic: 0, system: 0) })
    }
}
