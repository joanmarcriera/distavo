import XCTest
@testable import DistavoCore

final class BenchmarkTests: XCTestCase {
    private let sixteenGB: UInt64 = 16 << 30
    private let eightGB: UInt64 = 8 << 30

    func testRecommendedPrefersQualityWhenComfortable() {
        let r = [BenchmarkResult(modelID: "large-v3-turbo", secondsPerAudioMinute: 6),
                 BenchmarkResult(modelID: "small", secondsPerAudioMinute: 2),
                 BenchmarkResult(modelID: "parakeet-tdt-v3", secondsPerAudioMinute: 1)]
        XCTAssertEqual(Benchmark.recommended(results: r, memoryBytes: eightGB).id, "large-v3-turbo",
                       "a measurement beats the 16 GB rule")
    }

    func testRecommendedFallsToSmallThenFastestThenMemoryRule() {
        let slowTurbo = [BenchmarkResult(modelID: "large-v3-turbo", secondsPerAudioMinute: 45),
                         BenchmarkResult(modelID: "small", secondsPerAudioMinute: 9)]
        XCTAssertEqual(Benchmark.recommended(results: slowTurbo, memoryBytes: sixteenGB).id, "small")
        let allSlow = [BenchmarkResult(modelID: "large-v3-turbo", secondsPerAudioMinute: 90),
                       BenchmarkResult(modelID: "small", secondsPerAudioMinute: 40)]
        XCTAssertEqual(Benchmark.recommended(results: allSlow, memoryBytes: sixteenGB).id, "small")
        let failed = [BenchmarkResult(modelID: "large-v3-turbo", secondsPerAudioMinute: 0, error: "boom")]
        XCTAssertEqual(Benchmark.recommended(results: failed, memoryBytes: sixteenGB).id, "large-v3-turbo")
        XCTAssertEqual(Benchmark.recommended(results: failed, memoryBytes: eightGB).id, "small")
        XCTAssertEqual(Benchmark.recommended(results: [], memoryBytes: eightGB).id, "small")
    }

    func testMeasuredOKUnlocksTheMemoryGate() {
        let r = [BenchmarkResult(modelID: "bsc-los", secondsPerAudioMinute: 30),
                 BenchmarkResult(modelID: "bsc-ca-3370h", secondsPerAudioMinute: 0, error: "out of memory")]
        let ok = Benchmark.measuredOK(r)
        XCTAssertEqual(ok, ["bsc-los"])
        let ids = EmbeddedModelCatalog.selectable(memoryBytes: eightGB, measuredOK: ok).map(\.id)
        XCTAssertTrue(ids.contains("bsc-los"))
        XCTAssertFalse(ids.contains("bsc-ca-3370h"))
        XCTAssertFalse(EmbeddedModelCatalog.selectable(memoryBytes: eightGB).map(\.id).contains("bsc-los"))
    }

    func testCaptionAndConfigRoundTrip() throws {
        XCTAssertNil(Benchmark.caption([]))
        let r = [BenchmarkResult(modelID: "large-v3-turbo", secondsPerAudioMinute: 6.06, peakMemoryMB: 2355),
                 BenchmarkResult(modelID: "parakeet-tdt-v3", secondsPerAudioMinute: 0, error: "no model")]
        let caption = try XCTUnwrap(Benchmark.caption(r))
        XCTAssertTrue(caption.hasPrefix("Measured on this Mac ("))
        XCTAssertTrue(caption.contains("6.1 s per minute of audio, peak 2.3 GB"))
        XCTAssertTrue(caption.contains("failed (no model)"))

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("distavo-bench-\(UUID().uuidString)/watcher-config.json")
        var cfg = Config(); cfg.benchmark = r
        try Config.save(cfg, to: url)
        let loaded = try Config.load(from: url)
        XCTAssertEqual(loaded.benchmark.map(\.modelID), ["large-v3-turbo", "parakeet-tdt-v3"])
        XCTAssertEqual(loaded.benchmark[0].peakMemoryMB, 2355)
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("\"seconds_per_audio_minute\""))
        // A config without the key, or with junk in it, still loads.
        try #"{"benchmark": "junk"}"#.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(try Config.load(from: url).benchmark, [])
    }
}
