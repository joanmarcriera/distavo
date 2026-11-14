import Foundation

/// Disk facts for the Recording pane (Vikunja #6670): how big the recordings folder is and how much
/// room its volume has left, so a user on a nearly full disk can see why and pick the compact format.
///
/// Pure and read-only. Both calls touch the file system, so the app runs them off the main thread when
/// the pane appears. Neither throws: a folder we cannot read gives `nil` ("unknown"), never a guess
/// and never a crash (the App Store edition may not hold access to a folder it has no bookmark for).
public enum RecordingStorage {
    /// Below this the pane adds a caption with the per-hour cost of each format.
    public static let lowSpaceBytes: Int64 = 25_000_000_000

    public static func isLowOnSpace(freeBytes: Int64) -> Bool { freeBytes < lowSpaceBytes }

    public static let lowSpaceCaption =
        "Less than 25 GB free: a one-hour recording takes about 1.4 GB (0.7 GB compact)."

    /// Total size in bytes of every regular file under `folder` (subfolders and hidden files included;
    /// symbolic links are not followed). A folder that does not exist yet is 0; a folder that exists but
    /// cannot be listed (permission, or not a folder) is `nil`.
    public static func folderBytes(at folder: URL) -> Int64? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: folder.path, isDirectory: &isDir) else { return 0 }
        guard isDir.boolValue, (try? fm.contentsOfDirectory(atPath: folder.path)) != nil else { return nil }
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let walker = fm.enumerator(at: folder, includingPropertiesForKeys: keys,
                                         options: [], errorHandler: { _, _ in true }) else { return nil }
        var total: Int64 = 0
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    /// Space a user could still use on the volume holding `url` ("important usage" counts purgeable
    /// space, like Finder). Walks up to the nearest existing ancestor first, so a recordings folder that
    /// has not been created yet reports its disk, not 0. 0 means the volume could not be read.
    public static func freeBytes(at url: URL) -> Int64 {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path) && probe.path != "/" {
            probe.deleteLastPathComponent()
        }
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    /// "Recordings folder: 7.1 GB · 18 GB free on this disk". `nil` = unknown.
    public static func summary(folderBytes: Int64?, freeBytes: Int64?) -> String {
        let size = folderBytes.map(format) ?? "size unknown"
        let free = freeBytes.map { "\(format($0)) free on this disk" } ?? "free space unknown"
        return "Recordings folder: \(size) · \(free)"
    }

    private static func format(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .decimal          // the 1.4 GB/hour figures elsewhere are decimal too
        f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return f.string(fromByteCount: bytes)
    }
}
