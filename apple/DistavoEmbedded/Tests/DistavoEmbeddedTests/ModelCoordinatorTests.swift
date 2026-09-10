import XCTest
import DistavoCore
@testable import DistavoEmbedded

final class ModelCoordinatorTests: XCTestCase {
    func testExclusiveAccessSerialisesWork() async throws {
        let c = ModelCoordinator()
        actor Log { var events: [String] = []; func add(_ s: String) { events.append(s) } }
        let log = Log()
        async let a: Void = c.withExclusiveAccess {
            await log.add("a-start"); try await Task.sleep(nanoseconds: 100_000_000); await log.add("a-end")
        }
        async let b: Void = c.withExclusiveAccess {
            await log.add("b-start"); await log.add("b-end")
        }
        _ = try await (a, b)
        let events = await log.events
        // b must not start while a is running, whichever runs first.
        XCTAssertTrue(events == ["a-start", "a-end", "b-start", "b-end"] || events == ["b-start", "b-end", "a-start", "a-end"], "\(events)")
    }

    func testFreeSpaceCheckIsRetryable() {
        let c = ModelCoordinator()
        XCTAssertThrowsError(try c.ensureFreeSpace(forMB: 100_000_000)) { error in   // ≈ 95 TiB (100 million MiB)
            XCTAssertTrue(error is RetryableDependencyError)
        }
        XCTAssertNoThrow(try c.ensureFreeSpace(forMB: 1))
    }

    func testFreeSpaceBytesWalksUpToNearestExistingAncestor() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("distavo-nonexistent-\(UUID().uuidString)/models")
        XCTAssertGreaterThan(EmbeddedModelStore.freeSpaceBytes(at: missing), 0)
    }

    func testLateProgressAfterResetIsIgnored() async {
        let c = ModelCoordinator()
        await c.beginDownload(id: "m")
        await c.noteDownload(id: "m", fraction: 0.5)
        let midway = await c.readiness(of: "m")
        XCTAssertEqual(midway, .downloading(fraction: 0.5))
        await c.noteDownload(id: "m", fraction: nil)           // terminal reset
        await c.noteDownload(id: "m", fraction: 0.9)           // late callback
        let after = await c.readiness(of: "m")
        XCTAssertNotEqual(after, .downloading(fraction: 0.9))  // must not resurrect
    }

    /// `prefetch` must not re-download a model already on disk. Runs against the
    /// real (unisolated — see the distavo-shared-config-no-isolation memory)
    /// Application Support store, so it only exercises models this dev Mac
    /// already has; if none are downloaded there is nothing to assert against.
    func testPrefetchSkipsAlreadyDownloadedModels() async throws {
        let alreadyDownloaded = EmbeddedModelCatalog.models.filter { EmbeddedModelStore.isDownloaded($0) }
        try XCTSkipIf(alreadyDownloaded.isEmpty, "No embedded models are downloaded on this Mac to test the skip path against.")
        let c = ModelCoordinator()
        actor Counter { var calls = 0; func increment() { calls += 1 } }
        let counter = Counter()
        let outcome = try await c.prefetch(ids: alreadyDownloaded.map(\.id), includeDetector: false) { _ in
            await counter.increment()
        }
        XCTAssertEqual(outcome, .completed)
        let calls = await counter.calls
        XCTAssertEqual(calls, 0)
    }

    /// A cancel requested before `prefetch` even starts must stop it before any
    /// model downloads — including the first one — and report `.cancelled`
    /// rather than the silent `.completed` a plain early `return` used to give
    /// (review finding: the button would otherwise show "Ready" for a run the
    /// user cancelled).
    func testPrefetchReturnsCancelledWithoutDownloading() async throws {
        let ids = ["bsc-ca-3370h", "parakeet-tdt-v3"]
        for id in ids {
            try XCTSkipIf(EmbeddedModelStore.isDownloaded(EmbeddedModelCatalog.model(id: id)),
                          "\(id) is already downloaded on this Mac; can't test the cancel-before-download path against it.")
        }
        let c = ModelCoordinator()
        await c.cancelDownloads()
        actor Counter { var calls = 0; func increment() { calls += 1 } }
        let counter = Counter()
        let outcome = try await c.prefetch(ids: ids, includeDetector: false) { _ in
            await counter.increment()
        }
        XCTAssertEqual(outcome, .cancelled)
        let calls = await counter.calls
        XCTAssertEqual(calls, 0)
    }

    // MARK: Manifest failure counter (I2, spec §7)

    func testManifestFailureCountIncrementsPerConsecutiveFailure() async {
        let c = ModelCoordinator()
        let first = await c.recordManifestFailure(id: "bsc-los")
        XCTAssertEqual(first, 1)
        let second = await c.recordManifestFailure(id: "bsc-los")
        XCTAssertEqual(second, 2)
        let count = await c.manifestFailureCount(id: "bsc-los")
        XCTAssertEqual(count, 2)
    }

    func testManifestFailureCountIsPerModelID() async {
        let c = ModelCoordinator()
        _ = await c.recordManifestFailure(id: "bsc-los")
        let other = await c.manifestFailureCount(id: "bsc-ca-3370h")
        XCTAssertEqual(other, 0)
    }

    /// A successful verification resets the count, so a model that fails once
    /// and then downloads cleanly gets the full two-strike allowance again.
    func testResetManifestFailuresClearsTheCount() async {
        let c = ModelCoordinator()
        _ = await c.recordManifestFailure(id: "bsc-los")
        await c.resetManifestFailures(id: "bsc-los")
        let count = await c.manifestFailureCount(id: "bsc-los")
        XCTAssertEqual(count, 0)
    }

    func testStorePathsLiveUnderTheSingleModelsFolder() {
        let root = EmbeddedModelStore.modelsDirectory.path
        XCTAssertTrue(EmbeddedModelStore.parakeetDirectory.path.hasPrefix(root))
        let custom = EmbeddedModelStore.whisperKitDirectory(repo: "Joanmarcriera/distavo-whisperkit-coreml", variant: "BSC-LT_whisper-large-v3-LoS")
        XCTAssertTrue(custom.path.hasPrefix(root))
        XCTAssertTrue(custom.path.hasSuffix("models/Joanmarcriera/distavo-whisperkit-coreml/BSC-LT_whisper-large-v3-LoS"))
    }
}
