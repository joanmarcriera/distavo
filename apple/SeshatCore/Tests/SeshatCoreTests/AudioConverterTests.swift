import XCTest
import AVFoundation
@testable import SeshatCore

final class AudioConverterTests: XCTestCase {

    /// Write a short stereo 44.1 kHz float WAV with a sine tone, returning its URL.
    private func makeSourceWav() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("seshat-src-\(UUID().uuidString).wav")
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
            .appendingPathComponent("seshat-out-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: dst) }

        try await AudioConverter.convertToWav(source: src, dest: dst)

        let out = try AVAudioFile(forReading: dst)
        XCTAssertEqual(out.fileFormat.sampleRate, 16000)
        XCTAssertEqual(out.fileFormat.channelCount, 1)
        XCTAssertGreaterThan(out.length, 0)
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
