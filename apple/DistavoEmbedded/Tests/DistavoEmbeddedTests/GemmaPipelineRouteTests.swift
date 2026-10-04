import XCTest
import DistavoCore
@testable import DistavoEmbedded

/// Pipeline-level behaviour of the local Gemma summary route that needs no
/// weights (Vikunja #2198): the defer-versus-fail decisions, driven through the
/// real `Pipeline.processOne` + `SummaryModelManager` with a fake fetch in an
/// isolated temp tree. Runs in CI; the real-model counterparts are in
/// `GemmaPipelineLiveTests` (DISTAVO_LIVE=1).
final class GemmaPipelineRouteTests: XCTestCase {

    private func requireDisk() throws {
        // The manager refuses to start a download without room for staging + final.
        try XCTSkipIf(EmbeddedModelStore.freeSpaceBytes() < 11 * 1024 * 1024 * 1024, "needs ~11 GB free to exercise the download gate")
    }

    /// Not downloaded and the user never pressed Download: the recording defers
    /// (never fails), nothing is fetched, transcription is not run (readiness is
    /// checked first), and no `.failed` marker is left behind.
    func testNotDownloadedWithoutOptInDefersAndStartsNoDownload() async throws {
        let rig = try GemmaRig(weights: nil, optedIn: false)
        let rec = try rig.addRecording(named: "Meeting 2026-07-07 14.59.07.wav")
        let result = await rig.process(rec)
        XCTAssertEqual(result.status, .deferredNeedLocal)
        XCTAssertTrue(result.message.contains("has not been downloaded"), result.message)
        XCTAssertTrue(result.message.contains("Download now"), "message must point at Settings: \(result.message)")
        try await Task.sleep(nanoseconds: 500_000_000)     // a wrongly-started task would have fetched by now
        XCTAssertEqual(rig.fetches.value, 0, "no download may start without the user's opt-in")
        XCTAssertEqual(rig.transcribes.value, 0, "readiness is decided before transcription")
        XCTAssertFalse(try rig.state().isFailed(result.base), "a deferral must not leave a .failed marker")
        XCTAssertFalse(FileManager.default.fileExists(atPath: rig.models.path), "nothing may be created under the models folder")
        let status = await rig.manager.status(GemmaRig.model)
        XCTAssertEqual(status, .notDownloaded)
        // Scanning again is just as quiet.
        _ = await rig.process(rec)
        XCTAssertEqual(rig.fetches.value, 0)
    }

    /// After "Remove" a scan must not bring the model back, even though the
    /// opt-in had been set before.
    func testRemovedModelIsNotAutoDownloadedByAScan() async throws {
        let rig = try GemmaRig(weights: nil, optedIn: true)
        await rig.manager.remove(GemmaRig.model)
        let rec = try rig.addRecording(named: "Meeting 2026-07-07 14.59.07.wav")
        for _ in 0..<2 {
            let result = await rig.process(rec)
            XCTAssertEqual(result.status, .deferredNeedLocal)
            XCTAssertTrue(result.message.contains("was removed"), result.message)
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(rig.fetches.value, 0)
        XCTAssertEqual(rig.transcribes.value, 0)
        let status = await rig.manager.status(GemmaRig.model)
        XCTAssertEqual(status, .removed)
    }

    /// A download that fails its checksum is discarded and retried once (the
    /// recording defers); failing a second time is final and says so, and the
    /// recording is then reported failed with that message (not retried forever).
    func testCorruptDownloadRetriesOnceThenFailsWithAClearMessage() async throws {
        try requireDisk()
        let rig = try GemmaRig(weights: nil, optedIn: true)   // serves empty files: the tokenizer sha rejects them
        let rec = try rig.addRecording(named: "Meeting 2026-07-07 14.59.07.wav")

        var result = await rig.process(rec)                     // 1st scan starts the download
        XCTAssertEqual(result.status, .deferredNeedLocal)
        try await rig.waitForDownloadToSettle()
        result = await rig.process(rec)                         // mismatch #1 -> discard + download again
        XCTAssertEqual(result.status, .deferredNeedLocal)
        XCTAssertTrue(result.message.contains("integrity check"), result.message)
        try await rig.waitForDownloadToSettle()
        result = await rig.process(rec)                         // mismatch #2 -> permanent
        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.message.contains("could not be downloaded intact"), result.message)
        XCTAssertTrue(result.message.contains("Apple Intelligence or Ollama"), "must tell the user what to do: \(result.message)")
        XCTAssertTrue(try rig.state().isFailed(result.base))
        XCTAssertEqual(rig.transcribes.value, 0)
        XCTAssertFalse(SummaryModelStore.isVerified(GemmaRig.model, root: rig.models))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: SummaryModelStore.stagingDirectory(for: GemmaRig.model, root: rig.models).path), "staging is cleaned up")
    }
}
