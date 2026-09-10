import XCTest
@testable import DistavoCore

final class EmbeddedSupportTests: XCTestCase {

    // MARK: Catalog

    func testCatalogLookupFallsBackToDefaultForUnknownID() {
        XCTAssertEqual(EmbeddedModelCatalog.model(id: "small").id, "small")
        XCTAssertEqual(EmbeddedModelCatalog.model(id: "no-such-model").id,
                       EmbeddedModelCatalog.defaultModelID)
    }

    func testRecommendationFollowsMemory() {
        let gb: UInt64 = 1024 * 1024 * 1024
        XCTAssertEqual(EmbeddedModelCatalog.recommended(memoryBytes: 8 * gb).id, "small")
        XCTAssertEqual(EmbeddedModelCatalog.recommended(memoryBytes: 16 * gb).id, "large-v3-turbo")
        XCTAssertEqual(EmbeddedModelCatalog.recommended(memoryBytes: 64 * gb).id, "large-v3-turbo")
    }

    func testNewCatalogEntriesExist() {
        XCTAssertEqual(EmbeddedModelCatalog.model(id: "parakeet-tdt-v3").engine, .parakeet)
        XCTAssertEqual(EmbeddedModelCatalog.model(id: "bsc-los").whisperKitRepo,
                       "Joanmarcriera/distavo-whisperkit-coreml")
        XCTAssertEqual(EmbeddedModelCatalog.model(id: "bsc-los").whisperKitName,
                       "BSC-LT_whisper-large-v3-LoS")
        XCTAssertEqual(EmbeddedModelCatalog.model(id: "bsc-ca-3370h").whisperKitName,
                       "BSC-LT_whisper-large-v3-ca-punctuated-3370h")
        XCTAssertNil(EmbeddedModelCatalog.model(id: "large-v3-turbo").whisperKitRepo)
    }

    func testLanguageCoverage() {
        XCTAssertTrue(EmbeddedModelCatalog.model(id: "bsc-los").languages.covers("gl"))
        XCTAssertFalse(EmbeddedModelCatalog.model(id: "bsc-los").languages.covers("en"))
        XCTAssertTrue(EmbeddedModelCatalog.model(id: "parakeet-tdt-v3").languages.covers("de"))
        XCTAssertFalse(EmbeddedModelCatalog.model(id: "parakeet-tdt-v3").languages.covers("ca"))
        XCTAssertTrue(EmbeddedModelCatalog.model(id: "large-v3-turbo").languages.covers("ca"))
    }

    func testMemoryFloorGatesBSCModels() {
        let gb: UInt64 = 1024 * 1024 * 1024
        let on8 = EmbeddedModelCatalog.selectable(memoryBytes: 8 * gb).map(\.id)
        XCTAssertFalse(on8.contains("bsc-los"))
        XCTAssertTrue(on8.contains("parakeet-tdt-v3"))
        let on16 = EmbeddedModelCatalog.selectable(memoryBytes: 16 * gb).map(\.id)
        XCTAssertTrue(on16.contains("bsc-los") && on16.contains("bsc-ca-3370h"))
    }

    func testAutomaticIsNotACatalogModel() {
        XCTAssertTrue(EmbeddedModelCatalog.isAutomatic("auto"))
        XCTAssertEqual(EmbeddedModelCatalog.model(id: "auto").id, EmbeddedModelCatalog.defaultModelID)
    }

    // MARK: Config migration

    /// A config written before the embedded backend existed must keep behaving
    /// as a WhisperX-server config after upgrade — never silently switch.
    func testExistingConfigWithoutBackendKeyStaysOnServer() throws {
        let json = """
        {"transcribe": {"whisperx_url": "http://10.0.0.5:9000", "model": "medium"}}
        """.data(using: .utf8)!
        let cfg = try JSONDecoder().decode(Config.self, from: json)
        XCTAssertEqual(cfg.transcribe.backend, "server")
        XCTAssertEqual(cfg.transcribe.whisperxURL, "http://10.0.0.5:9000")
        XCTAssertEqual(cfg.transcribe.embeddedModel, EmbeddedModelCatalog.defaultModelID)
    }

    func testBackendAndEmbeddedModelRoundTrip() throws {
        var cfg = Config()
        cfg.transcribe.backend = "embedded"
        cfg.transcribe.embeddedModel = "small"
        let data = try JSONEncoder().encode(cfg)
        let back = try JSONDecoder().decode(Config.self, from: data)
        XCTAssertEqual(back.transcribe.backend, "embedded")
        XCTAssertEqual(back.transcribe.embeddedModel, "small")
    }

    func testFreshInstallDefaultsToEmbeddedOnSupportedHardware() {
        let gb: UInt64 = 1024 * 1024 * 1024
        let silicon16 = Config.recommendedForThisMac(embeddedSupported: true, memoryBytes: 16 * gb)
        XCTAssertEqual(silicon16.transcribe.backend, "embedded")
        XCTAssertEqual(silicon16.transcribe.embeddedModel, "large-v3-turbo")

        let silicon8 = Config.recommendedForThisMac(embeddedSupported: true, memoryBytes: 8 * gb)
        XCTAssertEqual(silicon8.transcribe.embeddedModel, "small")

        let intel = Config.recommendedForThisMac(embeddedSupported: false, memoryBytes: 32 * gb)
        XCTAssertEqual(intel.transcribe.backend, "server")
    }

    func testLoadUsesFreshDefaultsOnlyWhenFileMissing() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("distavo-test-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("watcher-config.json")
        defer { try? FileManager.default.removeItem(at: dir) }

        var fresh = Config()
        fresh.transcribe.backend = "embedded"
        let first = try Config.load(from: url, fresh: fresh)
        XCTAssertEqual(first.transcribe.backend, "embedded")

        // Second load reads the file; a different `fresh` must be ignored.
        var otherFresh = Config()
        otherFresh.transcribe.backend = "server"
        otherFresh.watchIntervalSeconds = 999
        let second = try Config.load(from: url, fresh: otherFresh)
        XCTAssertEqual(second.transcribe.backend, "embedded")
        XCTAssertNotEqual(second.watchIntervalSeconds, 999)
    }

    // MARK: Local-network warning scope

    func testEmbeddedBackendIgnoresWhisperXURLForLocalNetworkWarning() {
        var cfg = Config()
        cfg.transcribe.whisperxURL = "http://192.168.1.50:9000"
        cfg.summarise.server.url = "http://127.0.0.1:11434"
        cfg.summarise.local.url = "http://127.0.0.1:11434"

        cfg.transcribe.backend = "server"
        XCTAssertTrue(NetworkScope.usesLocalNetwork(cfg))

        cfg.transcribe.backend = "embedded"
        XCTAssertFalse(NetworkScope.usesLocalNetwork(cfg))
    }
}
