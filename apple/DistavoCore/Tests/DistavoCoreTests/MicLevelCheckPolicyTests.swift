import XCTest
@testable import DistavoCore

/// #3930 follow-ups: 9 s arrival, NaN, Ignore, label withdrawal, off switch, shared signal, config key.
final class MicLevelCheckPolicyTests: XCTestCase {
    private func feed(_ c: inout MicLevelCheck, mic: (Int) -> Float, seconds: Int, system: Float = 0.2) -> [Int] {
        (1...seconds).filter { c.ingest(mic: mic($0), system: system) }
    }
    func testMicArrivesAtNineSecondsNoWarning() {
        var c = MicLevelCheck()
        XCTAssertEqual(feed(&c, mic: { $0 == 9 ? 0.2 : 0 }, seconds: 30), [])
        XCTAssertFalse(c.warning)
    }
    func testNaNCountsAsSilence() {
        var c = MicLevelCheck()
        XCTAssertEqual(feed(&c, mic: { _ in .nan }, seconds: 30), [10])
    }
    func testIgnoreEndsCheckAndWithdrawsLabel() {
        var c = MicLevelCheck()
        _ = feed(&c, mic: { _ in 0 }, seconds: 10)
        XCTAssertTrue(c.warning)
        c.ignore()
        XCTAssertFalse(c.warning)
        XCTAssertEqual(feed(&c, mic: { _ in 0 }, seconds: 30), [])
    }
    func testWarningLabelWithdrawsWhenSoundArrives() {
        var c = MicLevelCheck()
        _ = feed(&c, mic: { _ in 0 }, seconds: 12)
        XCTAssertTrue(c.warning)
        _ = c.ingest(mic: 0.3, system: 0.2)
        XCTAssertFalse(c.warning)
    }
    func testWindowZeroIsOff() {
        var c = MicLevelCheck(window: 0)
        XCTAssertEqual(feed(&c, mic: { _ in 0 }, seconds: 60), [])
    }
    func testSharedSignalCountsConsecutiveSilence() {
        var s = MicSilenceSignal()
        for _ in 0..<5 { s.ingest(mic: 0) }
        XCTAssertEqual(s.silentSeconds, 5)
        s.ingest(mic: 0.5)
        XCTAssertEqual(s.silentSeconds, 0)
        XCTAssertTrue(s.everHeard)
        s.ingest(mic: 0)
        s.restartStretch()
        XCTAssertEqual(s.silentSeconds, 0)
    }
    func testConfigKeyDefaultsClampsAndDecodes() throws {
        XCTAssertEqual(Config().micSilenceWarningSeconds, 10)
        let big = try JSONDecoder().decode(Config.self, from: Data(#"{"mic_silence_warning_seconds": 999}"#.utf8))
        XCTAssertEqual(big.micSilenceWarningSeconds, 120)
        let off = try JSONDecoder().decode(Config.self, from: Data(#"{"mic_silence_warning_seconds": 0}"#.utf8))
        XCTAssertEqual(off.micSilenceWarningSeconds, 0)
        let none = try JSONDecoder().decode(Config.self, from: Data("{}".utf8))
        XCTAssertEqual(none.micSilenceWarningSeconds, 10)
    }
}
