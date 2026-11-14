import XCTest
import AVFoundation
@testable import DistavoCore

/// Vikunja #6670: Float32 stereo 48 kHz is 1.38 GB per hour; `recording.storage_format = int16` halves it.
final class RecordingStorageFormatTests: XCTestCase {

    func testSizesPerHour() {
        XCTAssertEqual(RecordingStorageFormat.full.bytesPerHour(sampleRate: 48_000), 1_382_400_000)
        XCTAssertEqual(RecordingStorageFormat.int16.bytesPerHour(sampleRate: 48_000), 691_200_000)
    }

    func testConfigDefaultsAndDecoding() throws {
        XCTAssertEqual(RecordingOptions().storageFormat, .full)
        XCTAssertEqual(Config.recommendedForThisMac(embeddedSupported: true, memoryBytes: 32 << 30).recording.storageFormat,
                       .full, "never switched on for anyone: opt-in only")
        XCTAssertEqual(try JSONDecoder().decode(RecordingOptions.self, from: Data("{}".utf8)).storageFormat, .full)
        XCTAssertEqual(try JSONDecoder().decode(RecordingOptions.self, from: Data(#"{"storage_format":"int16"}"#.utf8)).storageFormat, .int16)
        // an unknown or wrong-typed value never fails the config
        XCTAssertEqual(try JSONDecoder().decode(RecordingOptions.self, from: Data(#"{"storage_format":"flac"}"#.utf8)).storageFormat, .full)
        XCTAssertEqual(try JSONDecoder().decode(RecordingOptions.self, from: Data(#"{"storage_format":3}"#.utf8)).storageFormat, .full)
        let enc = try JSONEncoder().encode(RecordingOptions(storageFormat: .int16))
        XCTAssertTrue(String(decoding: enc, as: UTF8.self).contains(#""storage_format":"int16""#))
    }

    /// Writes a 2-second stereo tone with the recorder's writer settings and checks size and round trip.
    private func write(_ format: RecordingStorageFormat, to url: URL) throws {
        let rate = 48_000.0
        let file = try AVAudioFile(forWriting: url, settings: format.fileSettings(sampleRate: rate),
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let buf = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 96_000))
        buf.frameLength = 96_000
        for i in 0..<96_000 {
            buf.floatChannelData![0][i] = 0.5 * sinf(Float(i) * 0.05)      // mic
            buf.floatChannelData![1][i] = 0.25 * sinf(Float(i) * 0.031)    // system
        }
        try file.write(from: buf)
    }

    func testWrittenFileSizeMatchesTheFormatAndStaysReadableAsFloat32() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let full = dir.appendingPathComponent("full.wav"), small = dir.appendingPathComponent("int16.wav")
        try write(.full, to: full); try write(.int16, to: small)

        let a = try FileManager.default.attributesOfItem(atPath: full.path)[.size] as! Int
        let b = try FileManager.default.attributesOfItem(atPath: small.path)[.size] as! Int
        XCTAssertEqual(a, 96_000 * 2 * 4, accuracy: 4096)
        XCTAssertEqual(b, 96_000 * 2 * 2, accuracy: 4096)
        XCTAssertLessThan(Double(b), Double(a) * 0.52)

        // Later stages read Float32 whatever the file holds: values agree within 16-bit quantisation.
        let r1 = try AVAudioFile(forReading: full, commonFormat: .pcmFormatFloat32, interleaved: false)
        let r2 = try AVAudioFile(forReading: small, commonFormat: .pcmFormatFloat32, interleaved: false)
        XCTAssertEqual(r2.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int, 16)
        XCTAssertEqual(r2.length, r1.length)
        let x = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: r1.processingFormat, frameCapacity: 96_000))
        let y = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: r2.processingFormat, frameCapacity: 96_000))
        try r1.read(into: x); try r2.read(into: y)
        for ch in 0..<2 {
            var worst: Float = 0
            for i in 0..<96_000 { worst = max(worst, abs(x.floatChannelData![ch][i] - y.floatChannelData![ch][i])) }
            XCTAssertLessThan(worst, 1.0 / 16_384, "channel \(ch)")
        }
    }

    func testTheConverterAndTheBalancerAcceptAnInt16Recording() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("rec.wav"), wav = dir.appendingPathComponent("work.wav")
        try write(.int16, to: src)
        try await AudioConverter.convertToWav(source: src, dest: wav)
        let out = try AVAudioFile(forReading: wav)
        XCTAssertEqual(out.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(out.length, 32_000, accuracy: 64)

        let balanced = dir.appendingPathComponent("balanced.wav")
        _ = try StereoBalancer.balance(from: src, to: balanced)
        let b = try AVAudioFile(forReading: balanced)
        XCTAssertEqual(b.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int, 16, "stays 16-bit end to end")
    }
}
