import XCTest
@testable import DistavoCore

final class ConfigTests: XCTestCase {

    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("distavo-cfg-\(UUID().uuidString)")
            .appendingPathComponent("watcher-config.json")
    }

    func testDefaultsMatchPython() {
        let c = Config()
        XCTAssertEqual(c.watchIntervalSeconds, 20)
        XCTAssertEqual(c.transcribe.whisperxURL, "http://127.0.0.1:9000")
        XCTAssertEqual(c.transcribe.model, "medium")
        XCTAssertEqual(c.summarise.backend, "server")
        XCTAssertEqual(c.summarise.server.model, "llama3.1:8b")
        XCTAssertFalse(c.summarise.allowLocalFallback)
        XCTAssertFalse(c.summarise.embeddedEnabled)
        XCTAssertEqual(c.summarise.options.numCtx, 65536)
        XCTAssertEqual(c.summarise.options.seed, 42)
        XCTAssertEqual(c.noteOwner, "Me")
        XCTAssertEqual(c.userSpeaker, "unknown")
    }

    func testLoadCreatesDefaultsWhenMissing() throws {
        let url = tempFile()
        let c = try Config.load(from: url)
        XCTAssertEqual(c.watchIntervalSeconds, 20)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testLoadMergesPartialOntoDefaults() throws {
        let url = tempFile()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json = """
        {"watch_interval_seconds": 60, "transcribe": {"model": "large-v3"}}
        """
        try json.write(to: url, atomically: true, encoding: .utf8)

        let c = try Config.load(from: url)
        XCTAssertEqual(c.watchIntervalSeconds, 60)
        XCTAssertEqual(c.transcribe.model, "large-v3")
        // Untouched keys keep their defaults (deep-merge parity).
        XCTAssertEqual(c.transcribe.whisperxURL, "http://127.0.0.1:9000")
        XCTAssertEqual(c.noteOwner, "Me")
        XCTAssertEqual(c.summarise.options.numCtx, 65536)
    }

    func testRoundTripPreservesValues() throws {
        let url = tempFile()
        var c = Config()
        c.noteOwner = "Marc"
        c.summarise.server.url = "http://192.168.0.5:30068"
        try Config.save(c, to: url)
        let loaded = try Config.load(from: url)
        XCTAssertEqual(loaded, c)
    }

    func testResolvePath() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        XCTAssertEqual(Config.resolvePath("/abs/x").path, "/abs/x")
        XCTAssertEqual(Config.resolvePath("~/y").path, home.appendingPathComponent("y").path)
        XCTAssertEqual(Config.resolvePath("notes").path,
                       home.appendingPathComponent("Documents/Distavo/notes").path)
    }

    func testApplyEnvOverrides() {
        var c = Config()
        c.applyEnvOverrides([
            "WHISPERX_URL": "http://192.168.0.5:9000",
            "OLLAMA_URL": "http://192.168.0.5:30068",
            "OLLAMA_MODEL": "qwen2.5:7b-instruct",
        ])
        XCTAssertEqual(c.transcribe.whisperxURL, "http://192.168.0.5:9000")
        XCTAssertEqual(c.summarise.server.url, "http://192.168.0.5:30068")
        XCTAssertEqual(c.summarise.local.url, "http://192.168.0.5:30068")
        XCTAssertEqual(c.summarise.server.model, "qwen2.5:7b-instruct")
    }

    // MARK: Embedded summarisation flag (Vikunja #336)

    /// A config written before the flag existed must decode with the feature
    /// OFF — upgrading must never silently switch a working Ollama user onto
    /// the on-device engine (same rule as transcribe.backend).
    func testConfigPredatingEmbeddedFlagDecodesDisabled() throws {
        let url = tempFile()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json = """
        {"summarise": {"backend": "server", "server": {"url": "http://nas:11434"}}}
        """
        try json.write(to: url, atomically: true, encoding: .utf8)
        let c = try Config.load(from: url)
        XCTAssertFalse(c.summarise.embeddedEnabled)
        XCTAssertEqual(c.summarise.backend, "server")
        XCTAssertEqual(c.summarise.server.url, "http://nas:11434")
    }

    func testEmbeddedFlagRoundTripsThroughJSON() throws {
        let url = tempFile()
        var c = Config()
        c.summarise.embeddedEnabled = true
        c.summarise.backend = "embedded"
        try Config.save(c, to: url)

        let raw = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(raw.contains("embedded_enabled"), "key must use the JSON snake_case name")

        let reloaded = try Config.load(from: url)
        XCTAssertTrue(reloaded.summarise.embeddedEnabled)
        XCTAssertEqual(reloaded.summarise.backend, "embedded")
    }

    /// Fresh installs must not opt into on-device summarisation either.
    func testRecommendedForThisMacKeepsEmbeddedSummarisationOff() {
        let c = Config.recommendedForThisMac(embeddedSupported: true,
                                             memoryBytes: 32 * 1024 * 1024 * 1024)
        XCTAssertFalse(c.summarise.embeddedEnabled)
        XCTAssertEqual(c.summarise.backend, "server")
    }
}
