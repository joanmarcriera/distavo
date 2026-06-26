import XCTest
@testable import SeshatCore

final class ConfigTests: XCTestCase {

    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("seshat-cfg-\(UUID().uuidString)")
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
                       home.appendingPathComponent("Documents/Seshat/notes").path)
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
}
