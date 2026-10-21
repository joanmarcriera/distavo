import XCTest
@testable import DistavoCore

final class MicLevelCheckTests: XCTestCase {
    private let loud: Float = 0.2, quiet: Float = 0

    private func run(_ c: inout MicLevelCheck, mic: [Float], system: [Float]) -> [Int] {
        var fired: [Int] = []
        for i in 0..<mic.count where c.ingest(mic: mic[i], system: system[i]) { fired.append(i + 1) }
        return fired
    }
    func testDeadMicWithCallAudibleWarnsOnceAtTen() {
        var c = MicLevelCheck()
        XCTAssertEqual(run(&c, mic: Array(repeating: quiet, count: 30), system: Array(repeating: loud, count: 30)), [10])
    }
    func testBothSilentLeftToStartLevelCheck() {
        var c = MicLevelCheck()
        XCTAssertEqual(run(&c, mic: Array(repeating: quiet, count: 30), system: Array(repeating: quiet, count: 30)), [])
    }
    func testMicSoundAtAnyPointCancels() {
        var c = MicLevelCheck()
        var mic = Array(repeating: quiet, count: 30); mic[8] = loud
        XCTAssertEqual(run(&c, mic: mic, system: Array(repeating: loud, count: 30)), [])
    }
}
