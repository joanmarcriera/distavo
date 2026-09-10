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

    func testStorePathsLiveUnderTheSingleModelsFolder() {
        let root = EmbeddedModelStore.modelsDirectory.path
        XCTAssertTrue(EmbeddedModelStore.parakeetDirectory.path.hasPrefix(root))
        let custom = EmbeddedModelStore.whisperKitDirectory(repo: "Joanmarcriera/distavo-whisperkit-coreml", variant: "BSC-LT_whisper-large-v3-LoS")
        XCTAssertTrue(custom.path.hasPrefix(root))
        XCTAssertTrue(custom.path.hasSuffix("models/Joanmarcriera/distavo-whisperkit-coreml/BSC-LT_whisper-large-v3-LoS"))
    }
}
