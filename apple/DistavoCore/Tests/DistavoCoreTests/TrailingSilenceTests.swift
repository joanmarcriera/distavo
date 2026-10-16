import AVFoundation
import XCTest
@testable import DistavoCore

/// Vikunja #2677: a long silent tail is cut at finalise time, and nothing else is touched.
final class TrailingSilenceTests: XCTestCase {

    private let rate = 16_000.0
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("distavo-trail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    /// A stereo WAV: `sound` seconds of a tone (both channels), then `silence` seconds of digital silence.
    private func wav(sound: Int, silence: Int, channels: UInt32 = 2, leadingSilence: Int = 0) throws -> URL {
        let url = dir.appendingPathComponent("rec-\(UUID().uuidString).wav")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let total = leadingSilence + sound + silence
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate))!
        for second in 0..<total {
            buffer.frameLength = AVAudioFrameCount(rate)
            let loud = second >= leadingSilence && second < leadingSilence + sound
            for ch in 0..<Int(channels) {
                for i in 0..<Int(rate) {
                    buffer.floatChannelData![ch][i] = loud ? Float(0.1 * sin(2 * .pi * 220 * Double(i) / rate)) : 0
                }
            }
            try file.write(from: buffer)
        }
        return url
    }

    private func seconds(_ url: URL) throws -> Double {
        let f = try AVAudioFile(forReading: url)
        return Double(f.length) / f.processingFormat.sampleRate
    }

    private var log: ActivityLog { ActivityLog(url: dir.appendingPathComponent("a.log")) }

    func testLongSilentTailIsCutButTheTwoSecondTailAndAllSoundStay() throws {
        let url = try wav(sound: 20, silence: 120)
        let removed = try TrailingSilence.trim(url, activityLog: log)
        XCTAssertEqual(try seconds(url), 22, accuracy: 0.1, "20 s of sound + 2 s kept")
        XCTAssertEqual(removed, 118, accuracy: 0.1)
        // Still a readable stereo file.
        XCTAssertEqual(try AVAudioFile(forReading: url).processingFormat.channelCount, 2)
    }

    func testShortSilenceUnderTheMinimumIsLeftAlone() throws {
        let url = try wav(sound: 20, silence: 25)
        let before = try Data(contentsOf: url)
        XCTAssertEqual(try TrailingSilence.trim(url, activityLog: log), 0)
        XCTAssertEqual(try Data(contentsOf: url), before, "byte-identical")
    }

    func testAllSilentFileIsNeverTouched() throws {
        let url = try wav(sound: 0, silence: 90)
        XCTAssertEqual(try TrailingSilence.trim(url, activityLog: log), 0)
        XCTAssertEqual(try seconds(url), 90, accuracy: 0.1)
    }

    func testLeadingSilenceAndMonoAreHandled() throws {
        let url = try wav(sound: 10, silence: 60, channels: 1, leadingSilence: 40)
        try TrailingSilence.trim(url, activityLog: log)
        XCTAssertEqual(try seconds(url), 52, accuracy: 0.1, "leading silence is not ours to cut")
    }

    func testKeepRule() {
        // 100 windows of 1 s; sound in window 9 (the 10th second) -> keep 10 + 2 s.
        var rms = [Float](repeating: 0, count: 100); rms[9] = 0.05
        XCTAssertEqual(TrailingSilence.framesToKeep(windowRMS: rms, windowSeconds: 1, totalFrames: 1_600_000, sampleRate: 16_000), 192_000)
        XCTAssertNil(TrailingSilence.framesToKeep(windowRMS: [Float](repeating: 0, count: 100), windowSeconds: 1, totalFrames: 1_600_000, sampleRate: 16_000))
        rms[9] = 0.001                                   // below the shared gate = silence
        XCTAssertNil(TrailingSilence.framesToKeep(windowRMS: rms, windowSeconds: 1, totalFrames: 1_600_000, sampleRate: 16_000))
    }
}
