import XCTest
import AVFoundation
@testable import DistavoCore

final class AudioConverterTests: XCTestCase {

    /// Write a short stereo 44.1 kHz float WAV with a sine tone, returning its URL.
    private func makeSourceWav() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("distavo-src-\(UUID().uuidString).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        let frames = AVAudioFrameCount(44100 / 4)  // 0.25s
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for ch in 0..<2 {
            let data = buffer.floatChannelData![ch]
            for i in 0..<Int(frames) {
                data[i] = Float(sin(Double(i) * 2.0 * Double.pi * 440.0 / 44100.0)) * 0.5
            }
        }
        // Scope the writer so it flushes/closes before we read the file.
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        return url
    }

    func testConvertProducesMono16kPCM() async throws {
        let src = try makeSourceWav()
        defer { try? FileManager.default.removeItem(at: src) }
        let dst = FileManager.default.temporaryDirectory
            .appendingPathComponent("distavo-out-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: dst) }

        try await AudioConverter.convertToWav(source: src, dest: dst)

        let out = try AVAudioFile(forReading: dst)
        XCTAssertEqual(out.fileFormat.sampleRate, 16000)
        XCTAssertEqual(out.fileFormat.channelCount, 1)
        XCTAssertGreaterThan(out.length, 0)
    }

    // MARK: File-to-file path (1.18: converting must never open an audio device)

    /// A stereo file with a tone on ONE side only (an in-app recording: left =
    /// microphone, right = system audio). `seconds` long at `rate`.
    private func makeOneSidedFile(ext: String, toneChannel: Int, rate: Double = 48000,
                                  seconds: Double = 1, settings: [String: Any]? = nil) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("distavo-side-\(UUID().uuidString).\(ext)")
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let frames = AVAudioFrameCount(rate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for ch in 0..<2 {
            let data = buffer.floatChannelData![ch]
            for i in 0..<Int(frames) {
                data[i] = ch == toneChannel ? Float(sin(Double(i) * 2.0 * Double.pi * 440.0 / rate)) * 0.8 : 0
            }
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings ?? format.settings)
            try file.write(from: buffer)
        }
        return url
    }

    private func rms(_ url: URL) throws -> (rms: Double, frames: Int, rate: Double, channels: Int) {
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let data = buffer.floatChannelData![0]
        var sum = 0.0
        for i in 0..<Int(buffer.frameLength) { sum += Double(data[i]) * Double(data[i]) }
        return (sqrt(sum / Double(max(1, buffer.frameLength))), Int(buffer.frameLength),
                file.fileFormat.sampleRate, Int(file.fileFormat.channelCount))
    }

    private func tempOut() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("distavo-out-\(UUID().uuidString).wav")
    }

    func testFilePathProducesMono16kOfTheRightLength() throws {
        let src = try makeOneSidedFile(ext: "wav", toneChannel: 0, seconds: 2)
        let dst = tempOut()
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst) }
        XCTAssertTrue(try AudioConverter.convertWithAudioFile(source: src, dest: dst))
        let out = try rms(dst)
        XCTAssertEqual(out.rate, 16000)
        XCTAssertEqual(out.channels, 1)
        XCTAssertEqual(Double(out.frames), 32000, accuracy: 400, "2 s at 16 kHz")
    }

    /// Either side of a stereo recording must survive the mixdown at the same level.
    func testFilePathKeepsBothSidesOfAStereoRecording() throws {
        var levels: [Double] = []
        for side in [0, 1] {
            let src = try makeOneSidedFile(ext: "wav", toneChannel: side)
            let dst = tempOut()
            defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst) }
            XCTAssertTrue(try AudioConverter.convertWithAudioFile(source: src, dest: dst))
            levels.append(try rms(dst).rms)
        }
        // A 0.8 sine on one of two channels mixed at 1/sqrt(2): 0.57 peak, 0.40 RMS.
        XCTAssertEqual(levels[0], 0.40, accuracy: 0.03)
        XCTAssertEqual(levels[1], levels[0], accuracy: 0.005, "left-only and right-only come out equally loud")
    }

    /// The new path and the asset-reader path agree on length and level.
    func testFilePathMatchesTheAssetReaderPath() async throws {
        let src = try makeOneSidedFile(ext: "wav", toneChannel: 1, rate: 44100, seconds: 1.5)
        let a = tempOut(), b = tempOut()
        defer { [src, a, b].forEach { try? FileManager.default.removeItem(at: $0) } }
        XCTAssertTrue(try AudioConverter.convertWithAudioFile(source: src, dest: a))
        try await AudioConverter.convertWithAssetReader(source: src, dest: b)
        let (new, old) = (try rms(a), try rms(b))
        XCTAssertEqual(Double(new.frames), Double(old.frames), accuracy: 400)
        XCTAssertEqual(new.rms, old.rms, accuracy: 0.03)
    }

    /// Full-scale sound on both sides clips instead of wrapping around.
    func testFilePathClipsInsteadOfWrapping() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("distavo-loud-\(UUID().uuidString).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000)!
        buffer.frameLength = 16000
        for ch in 0..<2 { for i in 0..<16000 { buffer.floatChannelData![ch][i] = 1.0 } }
        do { try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer) }
        let dst = tempOut()
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: dst) }
        XCTAssertTrue(try AudioConverter.convertWithAudioFile(source: url, dest: dst))
        XCTAssertGreaterThan(try rms(dst).rms, 0.95, "a wrapped Int16 would come out negative or near zero")
    }

    func testFilePathDecodesCompressedAudio() throws {
        let aac: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000,
                                  AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128000]
        let src = try makeOneSidedFile(ext: "m4a", toneChannel: 0, seconds: 2, settings: aac)
        let dst = tempOut()
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst) }
        XCTAssertTrue(try AudioConverter.convertWithAudioFile(source: src, dest: dst))
        let out = try rms(dst)
        XCTAssertEqual(Double(out.frames), 32000, accuracy: 1600)
        XCTAssertEqual(out.rms, 0.40, accuracy: 0.04)
    }

    /// Something AVAudioFile cannot open is handed to the asset reader, not failed.
    func testFilePathDeclinesWhatItCannotOpen() throws {
        let junk = FileManager.default.temporaryDirectory.appendingPathComponent("distavo-junk-\(UUID().uuidString).mov")
        try Data("not audio".utf8).write(to: junk)
        defer { try? FileManager.default.removeItem(at: junk) }
        XCTAssertFalse(try AudioConverter.convertWithAudioFile(source: junk, dest: tempOut()))
    }

    func testUnsupportedExtensionThrowsActionableError() async {
        let mkv = URL(fileURLWithPath: "/tmp/whatever.mkv")
        let dst = URL(fileURLWithPath: "/tmp/out.wav")
        do {
            try await AudioConverter.convertToWav(source: mkv, dest: dst)
            XCTFail("expected throw for .mkv")
        } catch let error as AudioConverterError {
            XCTAssertTrue(error.message.lowercased().contains("mkv"))
            XCTAssertTrue(error.message.lowercased().contains("convert"))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}
