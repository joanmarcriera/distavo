import XCTest
@testable import DistavoCore

/// `Config.homeDir`: the real home unless a DEBUG build is given `DISTAVO_TEST_HOME` (not set in the test run).
final class TestHomeTests: XCTestCase {
    func testWithoutTheVariableEveryPathHangsFromTheRealHome() {
        guard ProcessInfo.processInfo.environment["DISTAVO_TEST_HOME"] == nil else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(Config.homeDir.path, home)
        XCTAssertEqual(Config.resolvePath("~/Documents/x").path, home + "/Documents/x")
        XCTAssertEqual(Config.resolvePath("~").path, home)
        XCTAssertEqual(Config.resolvePath("/tmp/x").path, "/tmp/x")
        XCTAssertEqual(Config.resolvePath("notes").path, home + "/Documents/Distavo/notes")
        XCTAssertTrue(Config.defaultConfigURL.path.hasPrefix(home + "/Library/Application Support/Distavo/"))
        XCTAssertTrue(ActivityLog.defaultURL.path.hasPrefix(home + "/Library/Logs/Distavo/"))
    }
}
