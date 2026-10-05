import XCTest
import AVFoundation
@testable import DistavoCore

/// Vikunja #2950: real AVFoundation export of a generated WAV, headless.
final class ClipExporterTests: XCTestCase {

    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("distavo-clip-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A WAV of `seconds` of sine tone (a different pitch per second) with the
    /// given sample rate and channel count.
    private func makeWav(at url: URL, seconds: Int, rate: Double, channels: AVAudioChannelCount) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ])
        let frames = AVAudioFrameCount(rate)
        for s in 0..<seconds {
            let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            buf.frameLength = frames
            for ch in 0..<Int(channels) {
                let p = buf.floatChannelData![ch]
                for i in 0..<Int(frames) { p[i] = 0.3 * Float(sin(2 * .pi * (300 + 100 * Double(s)) * Double(i) / rate)) }
            }
            try file.write(from: buf)
        }
    }

    private func m4aDuration(_ url: URL) async throws -> Double {
        CMTimeGetSeconds(try await AVURLAsset(url: url).load(.duration))
    }

    func testExportsStereoRecorderWavSubRange() async throws {
        let dir = tempDir()
        let src = dir.appendingPathComponent("rec.wav")
        try makeWav(at: src, seconds: 20, rate: 48_000, channels: 2)
        let dest = dir.appendingPathComponent("clip.m4a")
        let range = RecordingBookmarks.clipRange(for: 12, before: 4, after: 6, duration: 20)!   // 8 ... 18
        try await ClipExporter.export(source: src, range: range, to: dest)
        let d = try await m4aDuration(dest)
        XCTAssertEqual(d, 10, accuracy: 0.1)
        let readable = try AVAudioFile(forReading: dest)   // a real, decodable m4a
        XCTAssertEqual(readable.processingFormat.channelCount, 2)
        let probed = await ClipExporter.duration(of: dest)
        XCTAssertEqual(probed ?? 0, 10, accuracy: 0.1)
    }

    func testExportsCompactedMono16kWav() async throws {
        let dir = tempDir()
        let src = dir.appendingPathComponent("compact.wav")
        try makeWav(at: src, seconds: 10, rate: 16_000, channels: 1)
        let dest = dir.appendingPathComponent("c.m4a")
        try await ClipExporter.export(source: src, range: .init(start: 2.5, end: 7.0), to: dest)
        let d = try await m4aDuration(dest)
        XCTAssertEqual(d, 4.5, accuracy: 0.1)
    }

    func testMissingSourceAndExistingDestinationAreClearErrors() async throws {
        let dir = tempDir()
        let range = RecordingBookmarks.ClipRange(start: 0, end: 5)
        do {
            try await ClipExporter.export(source: dir.appendingPathComponent("gone.wav"), range: range,
                                          to: dir.appendingPathComponent("o.m4a"))
            XCTFail("expected a failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("no longer at"), error.localizedDescription)
        }
        let src = dir.appendingPathComponent("s.wav")
        try makeWav(at: src, seconds: 3, rate: 16_000, channels: 1)
        let existing = dir.appendingPathComponent("o.m4a")
        try Data([9]).write(to: existing)
        do {
            try await ClipExporter.export(source: src, range: range, to: existing)
            XCTFail("expected a failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("not overwriting"))
        }
        XCTAssertEqual(try Data(contentsOf: existing), Data([9]), "the existing file is untouched")
    }

    func testNonAudioSourceFailsWithoutLeavingAClip() async throws {
        let dir = tempDir()
        let src = dir.appendingPathComponent("junk.wav")
        try Data(repeating: 7, count: 64).write(to: src)
        let dest = dir.appendingPathComponent("o.m4a")
        do {
            try await ClipExporter.export(source: src, range: .init(start: 0, end: 1), to: dest)
            XCTFail("expected a failure")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
    }

    func testUniqueNamesNeverOverwrite() {
        let folder = URL(fileURLWithPath: "/x")
        XCTAssertEqual(ClipExporter.timeLabel(192), "03m12s")
        XCTAssertEqual(ClipExporter.timeLabel(3725), "1h02m05s")
        var taken: Set<String> = []
        func next() -> String {
            let u = ClipExporter.uniqueDestination(folder: folder, base: "Meeting", markerSeconds: 192.7) { taken.contains($0.lastPathComponent) }
            taken.insert(u.lastPathComponent)
            return u.lastPathComponent
        }
        XCTAssertEqual(next(), "Meeting clip 03m12s.m4a")
        XCTAssertEqual(next(), "Meeting clip 03m12s 2.m4a")
        XCTAssertEqual(next(), "Meeting clip 03m12s 3.m4a")
    }

    func testExportClipsOnePerMarkerAndReportsMissingSource() async throws {
        let dir = tempDir()
        let src = dir.appendingPathComponent("r.wav")
        try makeWav(at: src, seconds: 12, rate: 16_000, channels: 1)
        let out = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let marks: [RecordingBookmarks.Mark] = [.init(offsetSeconds: 3), .init(offsetSeconds: 6)]   // overlapping
        let results = await ClipExporter.exportClips(source: src, marks: marks, base: "r", folder: out, before: 2, after: 4)
        XCTAssertEqual(results.compactMap(\.url).map(\.lastPathComponent), ["r clip 00m03s.m4a", "r clip 00m06s.m4a"])
        let first = try await m4aDuration(results[0].url!)
        XCTAssertEqual(first, 6, accuracy: 0.1)
        let again = await ClipExporter.exportClips(source: src, marks: [marks[0]], base: "r", folder: out, before: 2, after: 4)
        XCTAssertEqual(again[0].url?.lastPathComponent, "r clip 00m03s 2.m4a")
        let missing = await ClipExporter.exportClips(source: dir.appendingPathComponent("nope.wav"), marks: marks, base: "r", folder: out, before: 2, after: 4)
        XCTAssertTrue(missing.allSatisfy { $0.url == nil && $0.error?.contains("no longer") == true })
    }
}
