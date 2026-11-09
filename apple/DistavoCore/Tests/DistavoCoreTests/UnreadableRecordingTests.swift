import XCTest
@testable import DistavoCore

/// Vikunja #5283 (finding 2 of docs/findings-real-meetings-2026-10-25.md): a recording whose
/// conversion fails identically twice gets a terminal `.unreadable` marker instead of being retried
/// on every launch. Driven through the `PipelineDeps` seam with synthetic bytes only.
final class UnreadableRecordingTests: XCTestCase {

    private struct Unreadable: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private func makeEnv() throws -> (Config, URL, DistavoState.Store) {
        let root = TestTemp.root
            .appendingPathComponent("distavo-unreadable-\(UUID().uuidString)")
        let rec = root.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: rec, withIntermediateDirectories: true)
        let input = rec.appendingPathComponent("broken.opus")
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

    private func deps(convertError: String) -> PipelineDeps {
        PipelineDeps(
            convertToWav: { _, _ in throw Unreadable(message: convertError) },
            transcribe: { _, _ in [:] },
            ollamaReachable: { _ in true },
            summarise: { _, _, _, _ in "" },
            audioDurationSeconds: { _ in nil })
    }

    private func pending(_ cfg: Config, _ store: DistavoState.Store) -> [String] {
        DistavoState.iterPending(recordingsDir: URL(fileURLWithPath: cfg.recordingsDir), state: store)
            .map(\.lastPathComponent)
    }

    func testSecondIdenticalConversionFailureIsTerminalAndSurvivesRetryFailed() async throws {
        let (cfg, input, store) = try makeEnv()
        let d = deps(convertError: "broken.opus: could not start reading (Cannot Open).")

        let first = await Pipeline.processOne(path: input, config: cfg, deps: d, stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(first.status, .failed)
        XCTAssertTrue(store.unreadableBases().isEmpty, "one failure is not yet terminal")

        store.retryFailed()                       // what every launch / "Process now" does
        XCTAssertEqual(pending(cfg, store), ["broken.opus"])

        let second = await Pipeline.processOne(path: input, config: cfg, deps: d, stableChecks: 1, stableDelay: 0)
        XCTAssertEqual(second.status, .failed)
        XCTAssertEqual(store.unreadableBases().map(\.base), ["broken"])

        store.retryFailed()
        XCTAssertTrue(pending(cfg, store).isEmpty, "a terminal file is not retried on launch")

        // A different file under the same name is a new recording: pending again.
        try Data(repeating: 7, count: 64).write(to: input)
        XCTAssertEqual(pending(cfg, store), ["broken.opus"])

        // The menu's explicit action clears it.
        try Data([0, 1, 2, 3]).write(to: input)
        store.clearUnreadable("broken")
        XCTAssertEqual(pending(cfg, store), ["broken.opus"])
    }

    /// Vikunja #5404: "Process now" must revive a terminal file whose size did not change
    /// (iCloud placeholder that finished downloading), while a launch-time `retryFailed` must not.
    func testRetryUnreadableReleasesTerminalFileAtSameSize() async throws {
        let (cfg, input, store) = try makeEnv()
        let d = deps(convertError: "broken.opus: could not start reading (Cannot Open).")
        for _ in 0..<2 {
            _ = await Pipeline.processOne(path: input, config: cfg, deps: d, stableChecks: 1, stableDelay: 0)
            store.retryFailed()
        }
        XCTAssertEqual(store.unreadableBases().map(\.base), ["broken"])
        XCTAssertTrue(pending(cfg, store).isEmpty)

        store.retryUnreadable()
        XCTAssertTrue(store.unreadableBases().isEmpty)
        XCTAssertEqual(pending(cfg, store), ["broken.opus"])

        // The failure count restarted: one more identical failure is not yet terminal.
        _ = await Pipeline.processOne(path: input, config: cfg, deps: d, stableChecks: 1, stableDelay: 0)
        XCTAssertTrue(store.unreadableBases().isEmpty)
    }

    func testDifferentFailuresDoNotAccumulateIntoATerminalState() async throws {
        let (cfg, input, store) = try makeEnv()
        _ = await Pipeline.processOne(path: input, config: cfg, deps: deps(convertError: "disk busy"),
                                      stableChecks: 1, stableDelay: 0)
        store.retryFailed()
        _ = await Pipeline.processOne(path: input, config: cfg, deps: deps(convertError: "permission denied"),
                                      stableChecks: 1, stableDelay: 0)
        XCTAssertTrue(store.unreadableBases().isEmpty, "only an identical repeat is terminal")
    }

    /// Vikunja #5477: a terminal file lives in the unreadable list only. If it also sat in the failed list,
    /// "Retry N failed recordings" (`retryFailed`) would clear that entry yet leave the file skipped.
    func testTerminalFileIsNotAlsoListedAsFailed() async throws {
        let (cfg, input, store) = try makeEnv()
        let d = deps(convertError: "broken.opus: could not start reading (Cannot Open).")
        for _ in 0..<2 {
            _ = await Pipeline.processOne(path: input, config: cfg, deps: d, stableChecks: 1, stableDelay: 0)
            if store.unreadableBases().isEmpty { store.retryFailed() }
        }
        XCTAssertEqual(store.unreadableBases().map(\.base), ["broken"])
        XCTAssertTrue(store.failedBases().isEmpty, "terminal file must not also appear in the failed list")
        XCTAssertFalse(store.isProcessing("broken"))
    }
}
