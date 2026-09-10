import XCTest
@testable import DistavoEmbedded
import DistavoCore

/// Runs `LanguageDetector.shared.detect(wavURL:)` against a REAL recording.
/// SKIPPED unless `DISTAVO_DETECTOR_LIVE=1`. Prints ONLY metrics (each
/// detection's code + probability, wall-clock, whether the 77 MB detector
/// model was already on disk before this run) — never transcript content, so
/// it is safe to run against a private meeting recording.
///
///   DISTAVO_DETECTOR_LIVE=1 \
///   DISTAVO_DETECTOR_AUDIO=/absolute/path/to/meeting.wav \
///   swift test --filter LanguageDetectorLiveTests
final class LanguageDetectorLiveTests: XCTestCase {

    func testDetectAgainstLiveRecording() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["DISTAVO_DETECTOR_LIVE"] == "1", "set DISTAVO_DETECTOR_LIVE=1 to run the live detector")

        let audioPath = try XCTUnwrap(
            env["DISTAVO_DETECTOR_AUDIO"], "set DISTAVO_DETECTOR_AUDIO to a WAV path")
        let wavURL = URL(fileURLWithPath: audioPath)

        let alreadyDownloaded = EmbeddedModelStore.isDetectorDownloaded()

        let start = Date()
        let detections = try await LanguageDetector.shared.detect(wavURL: wavURL)
        let elapsed = Date().timeIntervalSince(start)

        print("LIVE detector model already on disk before this run: \(alreadyDownloaded)")
        print("LIVE detector wall-clock: \(String(format: "%.1f", elapsed))s")
        for d in detections {
            print("LIVE detection: code=\(d.code) probability=\(String(format: "%.3f", d.probability))")
        }

        XCTAssertFalse(detections.isEmpty, "the detector should return at least one detection")
    }
}
