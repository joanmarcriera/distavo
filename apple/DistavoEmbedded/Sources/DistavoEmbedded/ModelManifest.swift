import Foundation
import CryptoKit

/// The `manifest.json` published alongside each custom (BSC Catalan) WhisperKit
/// model, written by `tools/whisperkit-models/manifest.py`. Keys under `files`
/// are paths relative to the model folder — nested `.mlmodelc` directories are
/// flattened to `dir/file` — and `manifest.json` itself is never one of them.
/// Argmax's own repo ships no manifest at all.
struct ModelManifest: Decodable {
    struct Entry: Decodable {
        let bytes: Int64
        let sha256: String
    }
    let files: [String: Entry]
}

/// Thrown by `ModelManifestCheck.verify` when a downloaded model folder does
/// not match its manifest — a partial or tampered download.
enum ModelManifestError: Error, LocalizedError {
    /// A file the manifest lists is absent on disk.
    case missing(file: String)
    /// A file's hash (or size) doesn't match what the manifest recorded.
    case mismatch(file: String)

    var errorDescription: String? {
        switch self {
        case let .missing(file): return "Manifest check: \(file) is missing."
        case let .mismatch(file): return "Manifest check: \(file) does not match."
        }
    }
}

/// Verifies a downloaded custom WhisperKit model folder against its
/// `manifest.json`, so a download interrupted mid-transfer (or tampered with)
/// is caught before it can produce silently-garbled transcripts.
enum ModelManifestCheck {
    /// Checks every file the manifest lists exists at `folder` with the
    /// recorded size and SHA-256. A no-op (returns immediately) when
    /// `folder` has no `manifest.json` — Argmax's repo, and any model folder
    /// downloaded before manifests existed.
    static func verify(folder: URL) throws {
        let manifestURL = folder.appendingPathComponent("manifest.json")
        guard let data = FileManager.default.contents(atPath: manifestURL.path) else { return }
        let manifest = try JSONDecoder().decode(ModelManifest.self, from: data)
        for (relativePath, entry) in manifest.files {
            let fileURL = folder.appendingPathComponent(relativePath)
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                throw ModelManifestError.missing(file: relativePath)
            }
            let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
            let size = (attributes?[.size] as? NSNumber)?.int64Value
            guard size == entry.bytes else {
                throw ModelManifestError.mismatch(file: relativePath)
            }
            guard try sha256Hex(of: fileURL) == entry.sha256 else {
                throw ModelManifestError.mismatch(file: relativePath)
            }
        }
    }

    /// Streamed SHA-256 in 1 MiB chunks — files here run to ~1.5 GB, so
    /// `Data(contentsOf:)` (which loads the whole file into memory) is not an
    /// option.
    private static func sha256Hex(of url: URL) throws -> String {
        guard let handle = FileHandle(forReadingAtPath: url.path) else {
            throw ModelManifestError.missing(file: url.lastPathComponent)
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        let chunkSize = 1 * 1024 * 1024
        while true {
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
