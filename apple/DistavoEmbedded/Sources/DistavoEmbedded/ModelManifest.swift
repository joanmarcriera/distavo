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
    /// Written into a variant folder immediately after a successful `verify`
    /// (I3): its presence means "this download was verified against its
    /// manifest", distinct from "the four expected files exist" — a download
    /// interrupted right after the model files land but before verification
    /// runs would otherwise look complete forever. Contents are the SHA-256 of
    /// `manifest.json` at the time of verification, kept for diagnostics.
    static let sentinelName = ".distavo-verified"

    /// Checks every file the manifest lists exists at `folder` with the
    /// recorded size and SHA-256.
    ///
    /// `expectManifest` distinguishes the two repos this is ever called
    /// against: Argmax's own repo (and any model folder downloaded before
    /// manifests existed) ships no `manifest.json` at all, so a missing
    /// manifest there is a silent no-op (`false`). A custom (BSC) repo always
    /// publishes one, so a missing manifest there (I3: a download that never
    /// even completed the manifest fetch) is itself a verification failure,
    /// not something to wave through (`true`).
    static func verify(folder: URL, expectManifest: Bool) throws {
        let manifestURL = folder.appendingPathComponent("manifest.json")
        guard let data = FileManager.default.contents(atPath: manifestURL.path) else {
            if expectManifest { throw ModelManifestError.missing(file: "manifest.json") }
            return
        }
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

    /// Marks `folder` as verified (I3) so `hasSentinel` can tell a completed,
    /// checked download apart from a folder that merely has the right files
    /// present — without re-hashing several GB of model weights on every load.
    static func writeSentinel(folder: URL) throws {
        let hash = try sha256Hex(of: folder.appendingPathComponent("manifest.json"))
        try hash.write(to: folder.appendingPathComponent(sentinelName), atomically: true, encoding: .utf8)
    }

    static func hasSentinel(folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(sentinelName).path)
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
