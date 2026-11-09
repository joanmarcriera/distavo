import XCTest
@testable import DistavoCore

/// Vikunja #5284: seam-level tests, synthetic text only.
final class EngineFallbackTests: XCTestCase {

    private func env() throws -> (Config, URL, DistavoState.Store) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("distavo-fallback-\(UUID().uuidString)")
        let rec = root.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: rec, withIntermediateDirectories: true)
        let input = rec.appendingPathComponent("demo.opus")
        try Data([0, 1, 2, 3]).write(to: input)
        var cfg = Config()
        cfg.recordingsDir = rec.path
        cfg.notesDir = root.appendingPathComponent("notes").path
        cfg.workDir = root.appendingPathComponent("work").path
        let store = try DistavoState.Store(
            stateDir: URL(fileURLWithPath: cfg.workDir).appendingPathComponent(".state"),
            notesDir: URL(fileURLWithPath: cfg.notesDir))
        return (cfg, input, store)
    }

    private func deps(transcribe: @escaping (URL, TranscribeConfig) async throws -> [String: Any],
                      summarise: @escaping (String, SummariseTarget, SummariseOptions, NoteContext) async throws -> String)
        -> PipelineDeps {
        PipelineDeps(
            convertToWav: { _, dest in
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data([0]).write(to: dest)
            },
            transcribe: transcribe, ollamaReachable: { _ in true }, summarise: summarise,
            audioDurationSeconds: { _ in nil })
    }

    // MARK: context too small defers (a)

    func testContextTooSmallFromTheDriverDefersAndIsNotFailed() async throws {
        let (cfg, input, store) = try env()
        let d = deps(
            transcribe: { _, _ in ["segments": [["speaker": "SPEAKER_00", "text": "hello world"]]] },
            summarise: { _, _, _, _ in
                // What the Apple adapter does while the model reports a 0-token window.
                let error = SummaryDriverError.contextTooSmall
                if let deferral = error.deferral(contextSize: 0) { throw deferral }
                throw error
            })
        let r = await Pipeline.processOne(path: input, config: cfg, deps: d, stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(r.status, .deferred)
        XCTAssertFalse(store.isFailed("demo"), "a failed marker would be skipped forever")
        XCTAssertNotNil(store.deferredUntil("demo"))
    }

    func testOtherDriverErrorsStayHardFailures() {
        XCTAssertNil(SummaryDriverError.emptyResult.deferral(contextSize: 0))
        XCTAssertNil(SummaryDriverError.promptTooLong(measured: 5000, contextSize: 4096).deferral(contextSize: 4096))
        XCTAssertNotNil(SummaryDriverError.contextTooSmall.deferral(contextSize: 0))
    }

    /// Review of the h chain (2026-11-09): with a real 4096-token window, "context too small" comes from
    /// the recording's own prompt (vocabulary, Quick Notes, template) and never changes on retry. Deferring
    /// it re-transcribed the file every 30 minutes for ever with no note and no error: it must fail.
    func testContextTooSmallWithARealWindowIsAHardFailure() {
        XCTAssertNil(SummaryDriverError.contextTooSmall.deferral(contextSize: 4096))
        XCTAssertNil(SummaryDriverError.contextTooSmall.deferral(contextSize: 600))
    }

    // MARK: Parakeet empty -> WhisperKit once (b)

    private struct EmptyOutput: EmptyTranscriptSignal { var isEmptyTranscript: Bool { true } }
    private struct Crash: EmptyTranscriptSignal { var isEmptyTranscript: Bool { false } }
    private static let heard: [String: Any] = ["segments": [["speaker": "SPEAKER_00", "text": "we heard this"]]]

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var c: [String: Int] = [:]
        func bump(_ k: String) { lock.lock(); c[k, default: 0] += 1; lock.unlock() }
        var counts: [String: Int] { lock.lock(); defer { lock.unlock() }; return c }
    }

    func testEmptyPrimaryErrorFallsBackOnceAndTheNoteIsWritten() async throws {
        let (cfg, input, store) = try env()
        let calls = Counter()
        let d = deps(
            transcribe: { _, _ in
                try await TranscribeFallback.run(
                    primary: { calls.bump("primary"); throw EmptyOutput() },
                    fallback: { calls.bump("fallback"); return EngineFallbackTests.heard }).result
            },
            summarise: { _, _, _, _ in PipelineTests.validNote })
        let r = await Pipeline.processOne(path: input, config: cfg, deps: d, stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(r.status, .done)
        XCTAssertEqual(calls.counts, ["primary": 1, "fallback": 1])
        XCTAssertTrue(store.isDone("demo"))
    }

    func testBlankPrimaryResultAlsoFallsBack() async throws {
        let r = try await TranscribeFallback.run(
            primary: { ["segments": [["speaker": "SPEAKER_00", "text": "   "]]] },
            fallback: { EngineFallbackTests.heard })
        XCTAssertTrue(r.usedFallback)
    }

    func testRealFailuresAndGoodOutputDoNotFallBack() async throws {
        let calls = Counter()
        let ok = try await TranscribeFallback.run(
            primary: { EngineFallbackTests.heard }, fallback: { calls.bump("fallback"); return [:] })
        XCTAssertFalse(ok.usedFallback)
        do {
            _ = try await TranscribeFallback.run(
                primary: { throw Crash() }, fallback: { calls.bump("fallback"); return [:] })
            XCTFail("a crash is not an empty transcript")
        } catch is Crash {}
        XCTAssertTrue(calls.counts.isEmpty)
    }

    func testFallbackThatIsAlsoEmptyEndsInTheNormalEmptyTranscriptFailure() async throws {
        let (cfg, input, store) = try env()
        let d = deps(
            transcribe: { _, _ in
                try await TranscribeFallback.run(primary: { throw EmptyOutput() }, fallback: { [:] }).result
            },
            summarise: { _, _, _, _ in PipelineTests.validNote })
        let r = await Pipeline.processOne(path: input, config: cfg, deps: d, stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(r.status, .failed)
        XCTAssertEqual(r.message, "empty transcript")
        XCTAssertTrue(store.isFailed("demo"))
    }
}
