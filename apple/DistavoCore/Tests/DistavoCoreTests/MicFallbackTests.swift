import XCTest
@testable import DistavoCore

/// Vikunja #4039: pure input-fallback policy. Synthetic levels only.
final class MicFallbackTests: XCTestCase {
    private let sound: Float = 0.2
    private let quiet: Float = 0

    /// Feed `seconds` samples of `level`; return the first non-.none action and its second.
    private func run(_ fb: inout MicFallback, level: Float, seconds: Int,
                     available: Set<String>) -> [MicFallback.Action] {
        (0..<seconds).map { _ in fb.ingest(mic: level, available: available) }.filter { $0 != .none }
    }

    func testDefaultSilentSecondHasSoundSwitchesOnceThenEnds() {
        var fb = MicFallback(ring: ["a", "b", "c"], window: 5)
        let all: Set = ["a", "b", "c"]
        XCTAssertEqual(run(&fb, level: quiet, seconds: 4, available: all), [])
        XCTAssertEqual(fb.ingest(mic: quiet, available: all), .switchTo("b"))   // 5th silent second
        XCTAssertEqual(fb.current, "b")
        XCTAssertEqual(fb.ingest(mic: sound, available: all), .none)
        XCTAssertTrue(fb.finished)
        // an ordinary pause later never moves the mic again
        XCTAssertEqual(run(&fb, level: quiet, seconds: 60, available: all), [])
        XCTAssertEqual(fb.current, "b")
    }

    func testAllSilentGoesBackToFirstAndStaysThere() {
        var fb = MicFallback(ring: ["a", "b", "c"], window: 3)
        let all: Set = ["a", "b", "c"]
        let actions = run(&fb, level: quiet, seconds: 300, available: all)
        XCTAssertEqual(actions, [.switchTo("b"), .switchTo("c"), .allSilent(returnTo: "a")])
        XCTAssertEqual(fb.current, "a")
        XCTAssertTrue(fb.finished)
    }

    func testSoundArrivingMidWindowCancelsSwitch() {
        var fb = MicFallback(ring: ["a", "b"], window: 5)
        let all: Set = ["a", "b"]
        XCTAssertEqual(run(&fb, level: quiet, seconds: 4, available: all), [])
        XCTAssertEqual(fb.ingest(mic: sound, available: all), .none)
        XCTAssertEqual(run(&fb, level: quiet, seconds: 30, available: all), [])
        XCTAssertEqual(fb.current, "a")
    }

    func testSingleInputDoesNothingAndEmptyRingIsSafe() {
        var one = MicFallback(ring: ["a"], window: 2)
        XCTAssertEqual(run(&one, level: quiet, seconds: 30, available: ["a"]), [])
        var none = MicFallback(ring: [], window: 2)
        XCTAssertEqual(none.ingest(mic: quiet, available: []), .none)
        XCTAssertNil(none.current)
    }

    func testDeviceUnpluggedMidRingIsSkipped() {
        var fb = MicFallback(ring: ["a", "b", "c"], window: 3)
        // b is unplugged by the time a's window ends: go straight to c
        XCTAssertEqual(run(&fb, level: quiet, seconds: 3, available: ["a", "c"]), [.switchTo("c")])
        XCTAssertEqual(fb.current, "c")
    }

    func testCurrentDeviceUnpluggedMovesOnImmediately() {
        var fb = MicFallback(ring: ["a", "b"], window: 30)
        XCTAssertEqual(fb.ingest(mic: quiet, available: ["b"]), .switchTo("b"))
    }

    func testFirstGoneAtTheEndLeavesTheRecorderWhereItIs() {
        var fb = MicFallback(ring: ["a", "b"], window: 2)
        XCTAssertEqual(run(&fb, level: quiet, seconds: 2, available: ["a", "b"]), [.switchTo("b")])
        // a vanishes, b stays silent: nothing to return to
        XCTAssertEqual(run(&fb, level: quiet, seconds: 2, available: ["b"]), [.allSilent(returnTo: nil)])
        XCTAssertEqual(fb.current, "b")
    }

    func testNaNAndNegativeCountAsSilence() {
        var fb = MicFallback(ring: ["a", "b"], window: 2)
        XCTAssertEqual(fb.ingest(mic: .nan, available: ["a", "b"]), .none)
        XCTAssertEqual(fb.ingest(mic: -1, available: ["a", "b"]), .switchTo("b"))
    }

    func testWindowClampedToAtLeastOne() {
        var fb = MicFallback(ring: ["a", "b"], window: 0)
        XCTAssertEqual(fb.ingest(mic: quiet, available: ["a", "b"]), .switchTo("b"))
    }

    // MARK: candidates

    func testCandidatesDefaultFirstRealInputsOnly() {
        let devs = [
            InputDeviceInfo(id: "ext", name: "USB Mic", inputChannels: 1),
            InputDeviceInfo(id: "bh", name: "BlackHole 2ch", inputChannels: 2, outputChannels: 2),
            InputDeviceInfo(id: "spk", name: "MacBook Speakers", inputChannels: 0, outputChannels: 2),
            InputDeviceInfo(id: "built", name: "MacBook Pro Microphone", inputChannels: 1),
            InputDeviceInfo(id: "zoom", name: "ZoomAudioDevice", inputChannels: 2),
            InputDeviceInfo(id: "agg", name: "Distavo Meeting Recorder", inputChannels: 3),
            InputDeviceInfo(id: "ext", name: "USB Mic dup", inputChannels: 1),
        ]
        XCTAssertEqual(MicCandidates.ordered(devices: devs, defaultID: "built").map(\.id), ["built", "ext"])
        XCTAssertEqual(MicCandidates.ordered(devices: devs, defaultID: nil).map(\.id), ["ext", "built"])
        // a default that is a loopback is not promoted
        XCTAssertEqual(MicCandidates.ordered(devices: devs, defaultID: "bh").map(\.id), ["ext", "built"])
    }

    // MARK: config

    func testConfigKeyInertForOldConfigAndOnForFreshInstall() throws {
        let old = try JSONDecoder().decode(Config.self, from: Data("{}".utf8))
        XCTAssertFalse(old.recording.micAutoSwitch)
        let wrong = try JSONDecoder().decode(Config.self, from: Data(#"{"recording":{"mic_auto_switch":"x"}}"#.utf8))
        XCTAssertFalse(wrong.recording.micAutoSwitch)
        XCTAssertTrue(Config.recommendedForThisMac(embeddedSupported: false, memoryBytes: 16 << 30).recording.micAutoSwitch)
        let rt = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(Config.recommendedForThisMac(embeddedSupported: false, memoryBytes: 16 << 30)))
        XCTAssertTrue(rt.recording.micAutoSwitch)
    }
}
