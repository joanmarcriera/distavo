import XCTest
import DistavoCore
@testable import DistavoEmbedded

final class ModelManifestTests: XCTestCase {
    func testVerifyPassesThenFailsOnTamper() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("abc".utf8).write(to: dir.appendingPathComponent("a.bin"))
        let sha = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        try Data(#"{"files": {"a.bin": {"bytes": 3, "sha256": "\#(sha)"}}}"#.utf8)
            .write(to: dir.appendingPathComponent("manifest.json"))
        XCTAssertNoThrow(try ModelManifestCheck.verify(folder: dir, expectManifest: true))
        try Data("abd".utf8).write(to: dir.appendingPathComponent("a.bin"))
        XCTAssertThrowsError(try ModelManifestCheck.verify(folder: dir, expectManifest: true))
    }

    /// A file the manifest lists but that is missing on disk (e.g. a download
    /// that stopped partway through) must be reported as `.missing`, not a
    /// generic file-not-found crash.
    func testMissingFileThrowsMissing() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"files": {"a.bin": {"bytes": 3, "sha256": "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"}}}"#.utf8)
            .write(to: dir.appendingPathComponent("manifest.json"))
        XCTAssertThrowsError(try ModelManifestCheck.verify(folder: dir, expectManifest: true)) { error in
            guard case ModelManifestError.missing(let file) = error else {
                return XCTFail("expected .missing, got \(error)")
            }
            XCTAssertEqual(file, "a.bin")
        }
    }

    /// Argmax's own repo (and any model folder that predates manifests) has no
    /// `manifest.json` at all — that must be a silent no-op, never an error,
    /// when the caller doesn't expect one.
    func testAbsentManifestIsNotAnErrorWhenNotExpected() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertNoThrow(try ModelManifestCheck.verify(folder: dir, expectManifest: false))
    }

    /// I3: a custom (BSC) repo always publishes a manifest. A download that
    /// never even completed the manifest fetch must not be waved through as
    /// "no manifest, nothing to check" — it must fail loudly (`.missing`), or
    /// a folder that never got its weights checked would look verified.
    func testMissingManifestForCustomRepoThrowsMissing() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertThrowsError(try ModelManifestCheck.verify(folder: dir, expectManifest: true)) { error in
            guard case ModelManifestError.missing(let file) = error else {
                return XCTFail("expected .missing, got \(error)")
            }
            XCTAssertEqual(file, "manifest.json")
        }
    }

    // MARK: Sentinel (I3)

    private func verifiedFolder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("abc".utf8).write(to: dir.appendingPathComponent("a.bin"))
        let sha = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        try Data(#"{"files": {"a.bin": {"bytes": 3, "sha256": "\#(sha)"}}}"#.utf8)
            .write(to: dir.appendingPathComponent("manifest.json"))
        return dir
    }

    func testSentinelAbsentUntilWritten() throws {
        let dir = try verifiedFolder()
        XCTAssertFalse(ModelManifestCheck.hasSentinel(folder: dir))
        try ModelManifestCheck.writeSentinel(folder: dir)
        XCTAssertTrue(ModelManifestCheck.hasSentinel(folder: dir))
    }

    /// The sentinel's contents are the manifest's own SHA-256, kept for
    /// diagnostics — not just an empty marker file.
    func testSentinelContentsAreManifestHash() throws {
        let dir = try verifiedFolder()
        try ModelManifestCheck.writeSentinel(folder: dir)
        let contents = try String(contentsOf: dir.appendingPathComponent(ModelManifestCheck.sentinelName), encoding: .utf8)
        XCTAssertEqual(contents.count, 64, "expected a hex SHA-256 string, got \(contents)")
    }

    // MARK: EmbeddedModelStore.isDownloaded x sentinel (I3)
    //
    // Writes into a uniquely-named, throwaway variant under the real
    // Application Support store (same pattern `EmbeddedModelStore` always
    // uses — there's no injectable root) and removes it afterwards, so this
    // never touches a variant name a real download would ever use.

    private func syntheticFiles(in dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["config.json", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"] {
            try Data().write(to: dir.appendingPathComponent(name))
        }
    }

    /// The whole point of I3: the three expected files existing is not enough
    /// for a custom-repo model — an interrupted download can leave exactly
    /// that shape without ever having been checked against its manifest.
    func testCustomRepoModelNotDownloadedWithoutSentinel() throws {
        let variant = "distavo-test-sentinel-\(UUID().uuidString)"
        let model = EmbeddedModel(
            id: "test-sentinel", displayName: "Test", engine: .whisperKit,
            whisperKitRepo: "Distavo-Test/sentinel-check", whisperKitName: variant,
            languages: .whisper, downloadMB: 0, ramGB: 0, minimumMemoryGB: 0, detail: "")
        let dir = EmbeddedModelStore.whisperKitDirectory(repo: model.whisperKitRepo, variant: model.whisperKitName)
        defer { try? FileManager.default.removeItem(at: dir) }
        try syntheticFiles(in: dir)

        XCTAssertFalse(EmbeddedModelStore.isDownloaded(model),
                       "the three files without a sentinel must not count as downloaded for a custom-repo model")

        try "deadbeef".write(to: dir.appendingPathComponent(ModelManifestCheck.sentinelName),
                             atomically: true, encoding: .utf8)
        XCTAssertTrue(EmbeddedModelStore.isDownloaded(model),
                     "the same folder with a sentinel must count as downloaded")
    }

    /// Argmax's own repo has no manifest to verify, so it never needs (or
    /// gets) a sentinel — the three files alone are enough, exactly as before I3.
    func testArgmaxModelDownloadedWithoutSentinel() throws {
        let variant = "distavo-test-argmax-\(UUID().uuidString)"
        let model = EmbeddedModel(
            id: "test-argmax", displayName: "Test", engine: .whisperKit,
            whisperKitRepo: nil, whisperKitName: variant,
            languages: .whisper, downloadMB: 0, ramGB: 0, minimumMemoryGB: 0, detail: "")
        let dir = EmbeddedModelStore.whisperKitDirectory(repo: nil, variant: variant)
        defer { try? FileManager.default.removeItem(at: dir) }
        try syntheticFiles(in: dir)

        XCTAssertTrue(EmbeddedModelStore.isDownloaded(model),
                     "an Argmax model needs no sentinel — the files alone are enough")
    }
}
