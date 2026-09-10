import XCTest
@testable import DistavoEmbedded

final class ModelManifestTests: XCTestCase {
    func testVerifyPassesThenFailsOnTamper() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("abc".utf8).write(to: dir.appendingPathComponent("a.bin"))
        let sha = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        try Data(#"{"files": {"a.bin": {"bytes": 3, "sha256": "\#(sha)"}}}"#.utf8)
            .write(to: dir.appendingPathComponent("manifest.json"))
        XCTAssertNoThrow(try ModelManifestCheck.verify(folder: dir))
        try Data("abd".utf8).write(to: dir.appendingPathComponent("a.bin"))
        XCTAssertThrowsError(try ModelManifestCheck.verify(folder: dir))
    }

    /// A file the manifest lists but that is missing on disk (e.g. a download
    /// that stopped partway through) must be reported as `.missing`, not a
    /// generic file-not-found crash.
    func testMissingFileThrowsMissing() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"files": {"a.bin": {"bytes": 3, "sha256": "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"}}}"#.utf8)
            .write(to: dir.appendingPathComponent("manifest.json"))
        XCTAssertThrowsError(try ModelManifestCheck.verify(folder: dir)) { error in
            guard case ModelManifestError.missing(let file) = error else {
                return XCTFail("expected .missing, got \(error)")
            }
            XCTAssertEqual(file, "a.bin")
        }
    }

    /// Argmax's own repo (and any model folder that predates manifests) has no
    /// `manifest.json` at all — that must be a silent no-op, never an error.
    func testAbsentManifestIsNotAnError() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertNoThrow(try ModelManifestCheck.verify(folder: dir))
    }
}
