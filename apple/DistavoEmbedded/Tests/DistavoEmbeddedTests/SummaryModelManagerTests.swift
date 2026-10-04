import XCTest
import CryptoKit
import DistavoCore
@testable import DistavoEmbedded

/// Download orchestration for the local summary model (Vikunja #2198 S5),
/// driven through a fake fetch so nothing touches the network or the real
/// models folder.
final class SummaryModelManagerTests: XCTestCase {

    private func tempRoot() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("distavo-sum-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// A tiny two-file model (one hashed, one size-only) with a fake repo.
    private func tinyModel(weights: Data = Data("weights".utf8)) -> EmbeddedSummaryModel {
        EmbeddedSummaryModel(
            id: "tiny", displayName: "Tiny", engine: .mlx, repo: "x/tiny", revision: "abc",
            downloadMB: 0, ramGB: 1, minimumMemoryGB: 0, contextCap: 1024, promptStyle: .classic,
            detail: "", files: [
                .init(path: "config.json", bytes: 2),
                .init(path: "model.safetensors", bytes: Int64(weights.count), sha256: sha(weights)),
            ])
    }

    private func fetching(_ payloads: [String: Data], calls: Box? = nil) -> SummaryFileFetch {
        { url, dest, onBytes in
            calls?.add(url.lastPathComponent)
            let data = payloads[url.lastPathComponent] ?? Data()
            try data.write(to: dest)
            onBytes(Int64(data.count))
        }
    }

    final class Box: @unchecked Sendable {
        private let lock = NSLock(); private var items: [String] = []
        func add(_ s: String) { lock.withLock { items.append(s) } }
        var all: [String] { lock.withLock { items } }
    }

    func testSuccessfulDownloadIsVerifiedAndMovedIntoPlace() async throws {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let model = tinyModel()
        let calls = Box()
        let manager = SummaryModelManager(root: root, coordinator: ModelCoordinator(),
                                          fetch: fetching(["config.json": Data("{}".utf8),
                                                           "model.safetensors": Data("weights".utf8)], calls: calls))
        var state = await manager.downloadState(model)
        XCTAssertEqual(state, .notStarted)
        try await manager.download(model)
        state = await manager.downloadState(model)
        XCTAssertEqual(state, .verified)
        XCTAssertTrue(SummaryModelStore.isVerified(model, root: root))
        XCTAssertEqual(calls.all.sorted(), ["config.json", "model.safetensors"])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: SummaryModelStore.stagingDirectory(for: model, root: root).path), "staging is gone")
    }

    func testFirstManifestMismatchIsRetryableSecondIsPermanent() async throws {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let model = tinyModel()
        // Right size, wrong bytes: only the SHA-256 notices.
        let corrupt = fetching(["config.json": Data("{}".utf8), "model.safetensors": Data("WEIGHTS".utf8)])
        let manager = SummaryModelManager(root: root, coordinator: ModelCoordinator(), fetch: corrupt)

        do { try await manager.download(model); XCTFail("expected a mismatch") } catch {}
        var state = await manager.downloadState(model)
        XCTAssertEqual(state, .manifestMismatch)            // -> temporarilyUnavailable, re-download
        XCTAssertFalse(SummaryModelStore.isVerified(model, root: root))

        do { try await manager.download(model); XCTFail("expected a mismatch") } catch {}
        state = await manager.downloadState(model)
        if case .failedPermanently = state {} else { XCTFail("two strikes must be permanent, got \(state)") }
    }

    func testPartialStagingFilesAreNotFetchedAgain() async throws {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let model = tinyModel()
        let staging = SummaryModelStore.stagingDirectory(for: model, root: root)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: staging.appendingPathComponent("config.json"))
        let calls = Box()
        let manager = SummaryModelManager(root: root, coordinator: ModelCoordinator(),
                                          fetch: fetching(["model.safetensors": Data("weights".utf8)], calls: calls))
        try await manager.download(model)
        XCTAssertEqual(calls.all, ["model.safetensors"])
    }

    func testFetchFailureIsRetryableNotPermanent() async throws {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let model = tinyModel()
        let manager = SummaryModelManager(root: root, coordinator: ModelCoordinator(),
                                          fetch: { _, _, _ in throw URLError(.notConnectedToInternet) })
        do { try await manager.download(model); XCTFail("expected an error") } catch {
            XCTAssertTrue(error is RetryableDependencyError)
        }
        let state = await manager.downloadState(model)
        XCTAssertEqual(state, .notStarted)
    }

    func testUnverifiedFolderWithoutSentinelIsNotReady() throws {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let model = tinyModel()
        let dir = SummaryModelStore.directory(for: model, root: root)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for f in model.files { try Data().write(to: dir.appendingPathComponent(f.path)) }
        XCTAssertFalse(SummaryModelStore.isVerified(model, root: root), "files without the sentinel are an interrupted download")
    }

    /// Integrity must not be weakenable by a manifest: an entry with no hash
    /// fails to decode, so verification throws instead of skipping the hash.
    func testManifestEntryWithoutSha256IsRejected() throws {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try Data("ab".utf8).write(to: root.appendingPathComponent("config.json"))
        try Data(#"{"files":{"config.json":{"bytes":2}}}"#.utf8).write(to: root.appendingPathComponent("manifest.json"))
        XCTAssertThrowsError(try ModelManifestCheck.verify(folder: root, expectManifest: true))
        XCTAssertThrowsError(try JSONDecoder().decode(
            ModelManifest.self, from: Data(#"{"files":{"a":{"bytes":1}}}"#.utf8)))
    }

    /// Small files are hashed locally and the hashes land in the manifest, so
    /// a same-size tamper of a small file is caught on verification.
    func testSmallFilesAreHashedIntoTheManifest() async throws {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let model = tinyModel()
        let manager = SummaryModelManager(root: root, coordinator: ModelCoordinator(),
                                          fetch: fetching(["config.json": Data("{}".utf8),
                                                           "model.safetensors": Data("weights".utf8)]))
        try await manager.download(model)
        let dir = SummaryModelStore.directory(for: model, root: root)
        let manifest = try JSONDecoder().decode(ModelManifest.self,
                                                from: Data(contentsOf: dir.appendingPathComponent("manifest.json")))
        XCTAssertEqual(manifest.files["config.json"]?.sha256, sha(Data("{}".utf8)))
        try Data("[]".utf8).write(to: dir.appendingPathComponent("config.json"))   // same size
        XCTAssertThrowsError(try ModelManifestCheck.verify(folder: dir, expectManifest: true))
    }

    /// A publisher hash that disagrees with the local one is a mismatch even
    /// when the size is right.
    func testPublisherHashMismatchFailsTheDownload() async throws {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let model = tinyModel()
        let manager = SummaryModelManager(root: root, coordinator: ModelCoordinator(),
                                          fetch: fetching(["config.json": Data("{}".utf8),
                                                           "model.safetensors": Data("WEIGHTS".utf8)]))
        do { try await manager.download(model); XCTFail("expected a mismatch") } catch {
            XCTAssertTrue(error is ModelManifestError)
        }
    }

    // MARK: Removal and recovery (review findings)

    /// remove() forgets a permanent failure and the manifest strikes, so a
    /// removed-then-redownloaded model starts with a clean slate.
    func testRemoveClearsPermanentFailureAndManifestStrikes() async throws {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let model = tinyModel()
        let coordinator = ModelCoordinator()
        let manager = SummaryModelManager(root: root, coordinator: coordinator,
                                          fetch: fetching(["config.json": Data("{}".utf8), "model.safetensors": Data("WEIGHTS".utf8)]))
        for _ in 0..<2 { do { try await manager.download(model) } catch {} }
        var state = await manager.downloadState(model)
        if case .failedPermanently = state {} else { XCTFail("setup: expected permanent, got \(state)") }
        await manager.remove(model)
        state = await manager.downloadState(model)
        XCTAssertEqual(state, .notStarted)
        let strikes = await coordinator.manifestFailureCount(id: model.id)
        XCTAssertEqual(strikes, 0)
    }

    /// remove() cancels an in-flight download and waits for it, so nothing is
    /// recreated afterwards.
    func testRemoveCancelsAnInFlightDownload() async throws {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let model = tinyModel()
        let started = Box()
        let manager = SummaryModelManager(root: root, coordinator: ModelCoordinator(), fetch: { _, _, _ in
            started.add("fetch")
            try await Task.sleep(nanoseconds: 60_000_000_000)   // until cancelled
        })
        await manager.startDownload(model)
        while started.all.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        var state = await manager.downloadState(model)
        if case .inProgress = state {} else { XCTFail("expected inProgress, got \(state)") }
        await manager.remove(model)
        state = await manager.downloadState(model)
        XCTAssertEqual(state, .notStarted, "the task ended; nothing is downloading")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: SummaryModelStore.stagingDirectory(for: model, root: root).path))
    }

    /// After "Remove downloaded models" the next scan must not silently start
    /// a fresh 5 GB download; Settings' explicit download re-enables it.
    func testRemovedModelIsNotAutoRedownloaded() async {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let fetches = Box()
        let manager = SummaryModelManager(root: root, coordinator: ModelCoordinator(),
                                          fetch: { url, _, _ in fetches.add(url.lastPathComponent); throw URLError(.cancelled) },
                                          memoryGB: 32, isAppleSilicon: true)
        let gemma = EmbeddedSummaryModelCatalog.model(id: "gemma-4-e4b")
        await manager.cancelAndForgetAll()
        let r = await manager.readiness(modelID: gemma.id)
        guard case .temporarilyUnavailable(let why) = r else { return XCTFail("expected a deferral, got \(r)") }
        XCTAssertTrue(why.contains("removed"), why)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(fetches.all.isEmpty, "no download was started")
    }

    /// A 5 GB download starts only after the user chose it in Settings.
    func testReadinessDoesNotDownloadWithoutOptIn() async {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let fetches = Box()
        let manager = SummaryModelManager(
            root: root, coordinator: ModelCoordinator(),
            fetch: { url, _, _ in fetches.add(url.lastPathComponent); throw URLError(.cancelled) },
            optIn: .inMemory(), memoryGB: 32, isAppleSilicon: true)
        let gemma = EmbeddedSummaryModelCatalog.model(id: "gemma-4-e4b")
        let r = await manager.readiness(modelID: gemma.id)
        guard case .temporarilyUnavailable(let why) = r else { return XCTFail("expected a deferral, got \(r)") }
        XCTAssertTrue(why.contains("Settings"), why)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(fetches.all.isEmpty, "no download was started")
        let s1 = await manager.status(gemma)
        XCTAssertEqual(s1, .notDownloaded)
        // The explicit action opts in; the transfer now starts.
        await manager.startDownload(gemma)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(fetches.all.isEmpty, "Download now starts the transfer")
        // Remove clears the opt-in and reports the removed state.
        await manager.remove(gemma)
        let s2 = await manager.status(gemma)
        XCTAssertEqual(s2, .removed)
    }

    /// Unreadable weights: the folder (with its sentinel) is deleted so the
    /// next readiness check sees "not downloaded"; a permanent message stops it.
    func testDiscardWeightsDeletesTheFolderAndCanMarkPermanent() async throws {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let model = tinyModel()
        let manager = SummaryModelManager(root: root, coordinator: ModelCoordinator(),
                                          fetch: fetching(["config.json": Data("{}".utf8), "model.safetensors": Data("weights".utf8)]))
        try await manager.download(model)
        XCTAssertTrue(SummaryModelStore.isVerified(model, root: root))
        await manager.discardWeights(model, permanentMessage: nil)
        var state = await manager.downloadState(model)
        XCTAssertEqual(state, .notStarted)
        await manager.discardWeights(model, permanentMessage: "unreadable twice")
        state = await manager.downloadState(model)
        XCTAssertEqual(state, .failedPermanently("unreadable twice"))
    }

    func testReadinessForAppleModelNeverStartsADownload() async {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let manager = SummaryModelManager(root: root, coordinator: ModelCoordinator(),
                                          fetch: { _, _, _ in XCTFail("no download for Apple's model") })
        let r = await manager.readiness(modelID: "apple")
        XCTAssertEqual(r, .ready)
    }

    func testGemmaSummariserDefersWhenWeightsAreMissing() async {
        // The real store root has no summary model in a test environment.
        do {
            _ = try await GemmaSummariser.summarise(
                transcript: "SPEAKER_00: hi", modelID: "gemma-4-e4b", noteOwner: "Marc",
                userSpeaker: "SPEAKER_00", participants: nil, style: .classic, meetingDate: nil, noteLanguage: nil)
            XCTFail("expected a deferral")
        } catch {
            // Either deferred (not downloaded) or, if a developer machine has
            // the model, it ran; never a permanent failure for a missing model.
            if !SummaryModelStore.isVerified(EmbeddedSummaryModelCatalog.model(id: "gemma-4-e4b")) {
                XCTAssertTrue(error is RetryableDependencyError)
            }
        }
    }
}
