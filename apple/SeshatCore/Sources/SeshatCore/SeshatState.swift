import Foundation

/// Default supported input extensions (mirrors `pipeline.SUPPORTED_EXTENSIONS`).
public let supportedExtensions: Set<String> = [
    ".wav", ".m4a", ".mp3", ".opus", ".ogg", ".flac", ".aac", ".m4b",
    ".mov", ".mp4", ".m4v", ".3gp", ".webm", ".mkv",
]

/// Port of `meeting_pipeline/state.py`: deterministic naming, marker files, and
/// pending-file detection. Named `SeshatState` to avoid clashing with SwiftUI's
/// `State`.
public enum SeshatState {

    private static let unsafeRegex = try! NSRegularExpression(pattern: "[^A-Za-z0-9_.-]+")

    private static func subUnsafe(_ s: String) -> String {
        let ns = s as NSString
        return unsafeRegex.stringByReplacingMatches(
            in: s, range: NSRange(location: 0, length: ns.length), withTemplate: "_")
    }

    private static func stripEdges(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet(charactersIn: "._-"))
    }

    /// Sanitise a raw file name into a safe stem (strips a trailing extension
    /// only when the name has a dot and no slash).
    public static func safeStem(_ name: String) -> String {
        let stem: String
        if name.contains(".") && !name.contains("/") {
            stem = (name as NSString).deletingPathExtension
        } else {
            stem = name
        }
        let safe = stripEdges(subUnsafe(stem))
        return safe.isEmpty ? "recording" : safe
    }

    /// Sanitise an already-joined path component without re-stripping extensions.
    public static func sanitizeJoined(_ name: String) -> String {
        let safe = stripEdges(subUnsafe(name.replacingOccurrences(of: "/", with: "_")))
        return safe.isEmpty ? "recording" : safe
    }

    /// Subfolder-aware base name so same-named files in different folders don't
    /// collide, preserving internal dots (e.g. dated file names).
    public static func baseFor(recordingsDir: URL, path: URL) -> String {
        let root = recordingsDir.standardizedFileURL.path
        let full = path.standardizedFileURL.path
        let relative: String
        if full == root {
            relative = path.lastPathComponent
        } else if full.hasPrefix(root + "/") {
            relative = String(full.dropFirst(root.count + 1))
        } else {
            relative = path.lastPathComponent
        }
        let noExt = (relative as NSString).deletingPathExtension
        let parts = noExt.split(separator: "/").map(String.init)
        return parts.map(sanitizeJoined).joined(separator: "__")
    }

    /// Wait until a file's size stops changing. Testable via injected providers.
    public static func waitUntilStable(
        checks: Int = 3,
        delay: Double = 2.0,
        sizeProvider: () -> Int?,
        sleep: (Double) -> Void = { _ in }
    ) -> Bool {
        var lastSize = -1
        var stable = 0
        while stable < checks {
            guard let size = sizeProvider() else { return false }
            if size == lastSize {
                stable += 1
            } else {
                stable = 0
                lastSize = size
            }
            sleep(delay)
        }
        return true
    }

    /// Production wrapper over a real file URL.
    public static func waitUntilStable(_ url: URL, checks: Int = 3, delay: Double = 2.0) -> Bool {
        waitUntilStable(
            checks: checks, delay: delay,
            sizeProvider: {
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                      let size = attrs[.size] as? Int else { return nil }
                return size
            },
            sleep: { Thread.sleep(forTimeInterval: $0) })
    }

    /// Marker/durability model: `<base>.processing|done|failed` under `stateDir`.
    public final class Store {
        public let stateDir: URL
        public let notesDir: URL
        private let fm = FileManager.default

        public init(stateDir: URL, notesDir: URL) throws {
            self.stateDir = stateDir
            self.notesDir = notesDir
            try fm.createDirectory(at: stateDir, withIntermediateDirectories: true)
        }

        public func notePath(_ base: String) -> URL {
            notesDir.appendingPathComponent("\(base).md")
        }

        private func marker(_ base: String, _ suffix: String) -> URL {
            stateDir.appendingPathComponent("\(base).\(suffix)")
        }

        private func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }
        private func write(_ text: String, _ url: URL) { try? text.write(to: url, atomically: true, encoding: .utf8) }
        private func remove(_ url: URL) { try? fm.removeItem(at: url) }

        public func isDone(_ base: String) -> Bool { exists(notePath(base)) || exists(marker(base, "done")) }
        public func isProcessing(_ base: String) -> Bool { exists(marker(base, "processing")) }
        public func isFailed(_ base: String) -> Bool { exists(marker(base, "failed")) }

        public func markProcessing(_ base: String) { write("processing\n", marker(base, "processing")) }
        public func clearProcessing(_ base: String) { remove(marker(base, "processing")) }
        public func clearFailed(_ base: String) { remove(marker(base, "failed")) }

        public func markDone(_ base: String) {
            write("done\n", marker(base, "done"))
            clearProcessing(base)
            clearFailed(base)
        }

        public func markFailed(_ base: String, _ error: String) {
            write(error + "\n", marker(base, "failed"))
            clearProcessing(base)
        }

        private func removeMarkers(suffix: String) {
            let items = (try? fm.contentsOfDirectory(
                at: stateDir, includingPropertiesForKeys: nil)) ?? []
            for url in items where url.pathExtension == suffix { remove(url) }
        }

        /// Remove leftover `.processing` markers (call when nothing is running —
        /// they indicate a prior crash mid-process).
        public func clearStaleProcessing() { removeMarkers(suffix: "processing") }

        /// Clear all `.failed` (and stale `.processing`) markers so every
        /// recording gets retried (the "Process now" path).
        public func retryFailed() {
            removeMarkers(suffix: "failed")
            removeMarkers(suffix: "processing")
        }
    }

    /// List recordings still needing work (recursive, sorted, marker-filtered).
    public static func iterPending(
        recordingsDir: URL, state: Store, extensions: Set<String> = supportedExtensions
    ) -> [URL] {
        let fm = FileManager.default
        guard let en = fm.enumerator(
            at: recordingsDir, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var files: [URL] = []
        for case let url as URL in en {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                files.append(url)
            }
        }
        files.sort { $0.path < $1.path }

        var pending: [URL] = []
        for url in files {
            let ext = "." + url.pathExtension.lowercased()
            if !extensions.contains(ext) { continue }
            let base = baseFor(recordingsDir: recordingsDir, path: url)
            if state.isDone(base) || state.isProcessing(base) || state.isFailed(base) { continue }
            pending.append(url)
        }
        return pending
    }
}
