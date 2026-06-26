import XCTest
@testable import SeshatCore

/// LAN-only end-to-end test. SKIPPED unless `SESHAT_LIVE=1`. Endpoints are read
/// from the environment — never hardcoded — so this is safe in CI/sandbox and
/// only runs where Marc's NAS is reachable. Real transcript content goes only to
/// the user-configured WhisperX/Ollama (no cloud path).
///
/// Run it on a machine that can reach the NAS:
///
///   SESHAT_LIVE=1 \
///   WHISPERX_URL=http://192.168.0.5:9000 \
///   OLLAMA_URL=http://192.168.0.5:30068 \
///   OLLAMA_MODEL=qwen2.5:7b-instruct \
///   SESHAT_LIVE_AUDIO=/absolute/path/to/sample.m4a \
///   swift test --filter LiveE2ETests
final class LiveE2ETests: XCTestCase {

    func testEndToEndAgainstLiveServers() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["SESHAT_LIVE"] == "1", "set SESHAT_LIVE=1 to run the live harness")

        let audioPath = try XCTUnwrap(
            env["SESHAT_LIVE_AUDIO"], "set SESHAT_LIVE_AUDIO to a sample recording path")
        let source = URL(fileURLWithPath: audioPath)

        var cfg = Config()
        cfg.applyEnvOverrides(env)  // WHISPERX_URL / OLLAMA_URL / OLLAMA_MODEL

        // 1) Convert with AVFoundation.
        let wav = FileManager.default.temporaryDirectory
            .appendingPathComponent("seshat-live-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        try await AudioConverter.convertToWav(source: source, dest: wav)

        // 2) Transcribe on the user's WhisperX.
        let result = try await WhisperXClient().transcribe(wavURL: wav, config: cfg.transcribe)
        let clean = TranscriptCleaner.clean(TranscriptCleaner.segments(from: result))
        XCTAssertFalse(clean.isEmpty, "transcript should not be empty")
        print("LIVE transcript (\(clean.count) chars):\n\(clean.prefix(400))")

        // 3) Summarise on the user's Ollama (local only — never cloud).
        let prompt = Prompt.build(
            transcript: clean, noteOwner: cfg.noteOwner, userSpeaker: cfg.userSpeaker)
        let summary = try await OllamaClient().generate(
            url: cfg.summarise.server.url, model: cfg.summarise.server.model,
            prompt: prompt, options: cfg.summarise.options)

        // 4) Validate.
        let failures = SummaryValidator.validate(summary)
        XCTAssertTrue(failures.isEmpty, "validation failures: \(failures)")
        XCTAssertTrue(summary.contains("#"), "summary should be Markdown")
        print("LIVE note (\(summary.count) chars):\n\(summary.prefix(600))")
    }
}
