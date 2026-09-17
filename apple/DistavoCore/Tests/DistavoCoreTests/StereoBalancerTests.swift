import XCTest
import AVFoundation
@testable import DistavoCore

final class StereoBalancerTests: XCTestCase {

    private var scratch: [URL] = []

    override func tearDown() {
        for url in scratch { try? FileManager.default.removeItem(at: url) }
        scratch = []
        super.tearDown()
    }

    private func tempURL(_ suffix: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("distavo-balance-\(UUID().uuidString)\(suffix)")
        scratch.append(url)
        return url
    }

    /// Write a stereo float32 WAV (the recorder's format) with a 440 Hz sine
    /// per channel at the given amplitudes.
    private func makeStereoWav(left: Float, right: Float,
                               seconds: Double = 1.0,
                               sampleRate: Double = 48000) throws -> URL {
        let url = tempURL(".wav.part")
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let frames = AVAudioFrameCount(sampleRate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(frames, 1))!
        buffer.frameLength = max(frames, 1)
        for (ch, amp) in [left, right].enumerated() {
            let data = buffer.floatChannelData![ch]
            for i in 0..<Int(buffer.frameLength) {
                data[i] = amp * Float(sin(Double(i) * 2.0 * .pi * 440.0 / sampleRate))
            }
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
        ]
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        }
        return url
    }

    /// Write a mono float32 WAV with a 440 Hz sine at the given amplitude.
    private func makeMonoWav(amplitude: Float, seconds: Double = 1.0,
                              sampleRate: Double = 48000) throws -> URL {
        let url = tempURL(".wav.part")
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let frames = AVAudioFrameCount(sampleRate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(frames, 1))!
        buffer.frameLength = max(frames, 1)
        let data = buffer.floatChannelData![0]
        for i in 0..<Int(buffer.frameLength) {
            data[i] = amplitude * Float(sin(Double(i) * 2.0 * .pi * 440.0 / sampleRate))
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
        ]
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        }
        return url
    }

    /// Channel count of a written file.
    private func channelCount(of url: URL) throws -> Int {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32,
                                    interleaved: false)
        return Int(file.processingFormat.channelCount)
    }

    /// A scratch `ActivityLog` writing to a temp file, so tests never touch
    /// the real `~/Library/Logs/Distavo/distavo.log`.
    private func scratchActivityLog() -> ActivityLog {
        ActivityLog(url: tempURL(".log"))
    }

    /// (rms per channel, peak per channel) of a whole file.
    private func analyze(_ url: URL) throws -> (rms: [Float], peak: [Float]) {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32,
                                   interleaved: false)
        let frames = AVAudioFrameCount(file.length)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)!
        try file.read(into: buffer)
        var rms: [Float] = []
        var peak: [Float] = []
        for ch in 0..<Int(file.processingFormat.channelCount) {
            let data = buffer.floatChannelData![ch]
            var sumSq: Float = 0
            var maxMag: Float = 0
            for i in 0..<Int(buffer.frameLength) {
                sumSq += data[i] * data[i]
                maxMag = max(maxMag, abs(data[i]))
            }
            rms.append(sqrt(sumSq / Float(max(1, Int(buffer.frameLength)))))
            peak.append(maxMag)
        }
        return (rms, peak)
    }

    func testQuietMicIsBoostedToMatchLoudSystemAudio() throws {
        let src = try makeStereoWav(left: 0.05, right: 0.5)  // 20 dB apart
        let dst = tempURL(".wav")

        try StereoBalancer.balance(from: src, to: dst)

        XCTAssertFalse(FileManager.default.fileExists(atPath: src.path), "source consumed")
        let (rms, peak) = try analyze(dst)
        XCTAssertGreaterThan(rms[0], 0.05, "quiet channel boosted")
        let ratio = rms[0] / rms[1]
        XCTAssertGreaterThan(ratio, 0.7, "channels within ~3 dB after balance (got \(ratio))")
        XCTAssertLessThanOrEqual(ratio, 1.3)
        XCTAssertLessThanOrEqual(peak[0], 1.0)
        XCTAssertLessThanOrEqual(peak[1], 1.0)
        // Loud (reference) channel untouched.
        XCTAssertEqual(rms[1], 0.5 / sqrt(2), accuracy: 0.01)
    }

    func testSilentChannelIsLeftAlone() throws {
        let src = try makeStereoWav(left: 0.0, right: 0.5)
        let dst = tempURL(".wav")

        try StereoBalancer.balance(from: src, to: dst)

        let (rms, _) = try analyze(dst)
        XCTAssertLessThan(rms[0], 0.0005, "silent channel must not be amplified")
        XCTAssertEqual(rms[1], 0.5 / sqrt(2), accuracy: 0.01)
    }

    func testAlreadyBalancedIsUnchanged() throws {
        let src = try makeStereoWav(left: 0.4, right: 0.4)
        let dst = tempURL(".wav")

        try StereoBalancer.balance(from: src, to: dst)

        let (rms, _) = try analyze(dst)
        XCTAssertEqual(rms[0], 0.4 / sqrt(2), accuracy: 0.01)
        XCTAssertEqual(rms[1], 0.4 / sqrt(2), accuracy: 0.01)
    }

    func testBoostIsCappedAndPeakLimited() throws {
        // ~43 dB apart, but audible (above silence floor and noise gate):
        // the wanted gain (~×150) must be capped at maxGain (×16).
        let src = try makeStereoWav(left: 0.006, right: 0.9)
        let dst = tempURL(".wav")

        try StereoBalancer.balance(from: src, to: dst)

        let (rms, peak) = try analyze(dst)
        XCTAssertLessThanOrEqual(peak[0], StereoBalancer.peakCeiling + 0.001)
        // Exactly the cap: ×16 of the original 0.006-amplitude sine.
        XCTAssertGreaterThan(rms[0], 0.05, "cap applied, not skipped")
        XCTAssertLessThanOrEqual(rms[0], 0.006 * 16.0 / sqrt(2) * 1.05)
        XCTAssertEqual(rms[1], 0.9 / sqrt(2), accuracy: 0.02)
    }

    func testVeryShortFileDoesNotCrash() throws {
        let src = try makeStereoWav(left: 0.1, right: 0.5, seconds: 0.01)
        let dst = tempURL(".wav")

        try StereoBalancer.balance(from: src, to: dst)

        XCTAssertTrue(FileManager.default.fileExists(atPath: dst.path))
    }

    // MARK: - Silent system-audio fallback (Vikunja #2060)

    func testSilentSystemAudioDownmixesToNormalizedMono() throws {
        // Left (mic) is quiet but present; right (system audio) never
        // registers at all — the tap failed silently.
        let src = try makeStereoWav(left: 0.02, right: 0.0)
        let dst = tempURL(".wav")
        let log = scratchActivityLog()

        try StereoBalancer.balance(from: src, to: dst, activityLog: log)

        XCTAssertEqual(try channelCount(of: dst), 1, "downmixed to mono")
        let (rms, peak) = try analyze(dst)
        XCTAssertEqual(rms[0], StereoBalancer.monoNormalizationTarget, accuracy: 0.02,
                       "loudness raised to the normalisation target")
        XCTAssertLessThanOrEqual(peak[0], StereoBalancer.peakCeiling + 0.001)
        XCTAssertTrue(log.recent().contains { $0.lowercased().contains("mono") },
                      "one Activity line records the fallback")
    }

    func testNormalStereoIsUntouchedByTheMonoFallback() throws {
        // Right channel has real signal — the mono fallback must not fire;
        // this stays on the ordinary stereo-balance path.
        let src = try makeStereoWav(left: 0.05, right: 0.5)
        let dst = tempURL(".wav")

        try StereoBalancer.balance(from: src, to: dst)

        XCTAssertEqual(try channelCount(of: dst), 2, "right channel has signal — stays stereo")
    }

    func testFullySilentStereoFileIsNeverAmplified() throws {
        let src = try makeStereoWav(left: 0.0, right: 0.0)
        let dst = tempURL(".wav")

        try StereoBalancer.balance(from: src, to: dst, activityLog: scratchActivityLog())

        let (rms, _) = try analyze(dst)
        XCTAssertLessThan(rms[0], 0.0005, "no signal to normalise — never amplified")
    }

    func testQuietMonoInputIsNormalized() throws {
        let src = try makeMonoWav(amplitude: 0.02)
        let dst = tempURL(".wav")
        let log = scratchActivityLog()

        try StereoBalancer.balance(from: src, to: dst, activityLog: log)

        XCTAssertEqual(try channelCount(of: dst), 1)
        let (rms, peak) = try analyze(dst)
        XCTAssertEqual(rms[0], StereoBalancer.monoNormalizationTarget, accuracy: 0.02)
        XCTAssertLessThanOrEqual(peak[0], StereoBalancer.peakCeiling + 0.001)
        XCTAssertTrue(log.recent().contains { $0.lowercased().contains("normalis") })
    }

    func testLoudMonoInputIsUnchanged() throws {
        // Already at/above target loudness: normalised only if quiet, so
        // this is left alone rather than attenuated.
        let src = try makeMonoWav(amplitude: 0.5)
        let dst = tempURL(".wav")

        try StereoBalancer.balance(from: src, to: dst)

        let (rms, _) = try analyze(dst)
        XCTAssertEqual(rms[0], 0.5 / sqrt(2), accuracy: 0.01, "already loud enough — left alone")
    }

    func testSilentMonoFileIsNeverAmplified() throws {
        let src = try makeMonoWav(amplitude: 0.0)
        let dst = tempURL(".wav")

        try StereoBalancer.balance(from: src, to: dst)

        let (rms, _) = try analyze(dst)
        XCTAssertLessThan(rms[0], 0.0005)
    }
}
