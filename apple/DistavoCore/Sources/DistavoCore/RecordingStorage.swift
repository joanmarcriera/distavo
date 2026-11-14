import Foundation

/// Disk facts for the Recording pane (Vikunja #6670): how big the recordings folder is and how much
/// room its volume has left, so a user on a nearly full disk can see why and pick the compact format.
///
/// Pure and read-only. Both calls touch the file system, so the app runs them off the main thread when
/// the pane appears. Neither throws: anything we cannot read gives `nil` ("unknown"), never a guess
/// and never a crash (the App Store edition may not hold access to a folder it has no bookmark for).
public enum RecordingStorage {
    /// Below this the pane adds a caption with the per-hour cost of each format.
    public static let lowSpaceBytes: Int64 = 25_000_000_000

    /// A folder with more entries than this is not walked to the end: the pane shows "at least X".
    public static let defaultMaxEntries = 200_000

    public static func isLowOnSpace(freeBytes: Int64) -> Bool { freeBytes < lowSpaceBytes }

    /// What a scan found. `isLowerBound` = the walk stopped at the entry cap, so the real size is larger.
    public struct FolderSize: Equatable, Sendable {
        public var bytes: Int64
        public var isLowerBound: Bool
        public init(bytes: Int64, isLowerBound: Bool) { self.bytes = bytes; self.isLowerBound = isLowerBound }
    }

    /// Space the files under `folder` occupy on disk (allocated size, so a cloud placeholder or sparse file
    /// does not overstate), counting regular files in subfolders and hidden files; symbolic links inside are
    /// not followed, a symbolic link at the root is resolved.
    ///
    /// * A folder that does not exist yet is 0 only when the nearest existing ancestor can be listed;
    ///   otherwise we cannot tell "missing" from "no access" (a sandboxed edition) and the result is `nil`.
    /// * A folder that exists but cannot be listed, or a path that is a file, is `nil`.
    /// * `isCancelled` is polled for every entry; once it returns true the scan stops and returns `nil`.
    public static func folderSize(at folder: URL,
                                  isCancelled: () -> Bool = { false },
                                  maxEntries: Int = defaultMaxEntries) -> FolderSize? {
        let fm = FileManager.default
        let root = folder.resolvingSymlinksInPath()
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir) else {
            return nearestExistingAncestorIsListable(root) ? FolderSize(bytes: 0, isLowerBound: false) : nil
        }
        guard isDir.boolValue, (try? fm.contentsOfDirectory(atPath: root.path)) != nil else { return nil }
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey,
                                      .fileAllocatedSizeKey, .fileSizeKey]
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: keys,
                                         options: [], errorHandler: { _, _ in true }) else { return nil }
        var total: Int64 = 0
        var entries = 0
        for case let url as URL in walker {
            if isCancelled() { return nil }
            if entries >= maxEntries { return FolderSize(bytes: total, isLowerBound: true) }
            entries += 1
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
        }
        return FolderSize(bytes: total, isLowerBound: false)
    }

    /// Free space a user could still use on the volume holding `url` ("important usage" counts purgeable
    /// space, like Finder). Walks up to the nearest existing ancestor first, so a recordings folder that
    /// has not been created yet reports its disk. 0 is a real 0 (a full disk); `nil` = could not be read.
    public static func freeBytes(at url: URL) -> Int64? {
        let probe = nearestExistingAncestor(of: url)
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// "Recordings folder: 7.1 GB · 18 GB free on this disk". `nil` = unknown.
    public static func summary(folder: FolderSize?, freeBytes: Int64?) -> String {
        let size = folder.map { ($0.isLowerBound ? "at least " : "") + format($0.bytes) } ?? "size unknown"
        let free = freeBytes.map { "\(format($0)) free on this disk" } ?? "free space unknown"
        return "Recordings folder: \(size) · \(free)"
    }

    /// The caption shown under the summary when the disk is short of room, or `nil`. With Compact already
    /// chosen only its own figure is named; the figures come from `RecordingStorageFormat.bytesPerHour`.
    public static func lowSpaceCaption(freeBytes: Int64?, format: RecordingStorageFormat) -> String? {
        guard let free = freeBytes, isLowOnSpace(freeBytes: free) else { return nil }
        let head = "Less than 25 GB free: a one-hour recording takes about"
        switch format {
        case .int16:
            return "\(head) \(RecordingStorageFormat.int16.gbPerHourLabel) GB."
        case .full:
            return "\(head) \(RecordingStorageFormat.full.gbPerHourLabel) GB "
                + "(\(RecordingStorageFormat.int16.gbPerHourLabel) GB compact)."
        }
    }

    // MARK: helpers

    private static func nearestExistingAncestor(of url: URL) -> URL {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path) && probe.path != "/" {
            probe.deleteLastPathComponent()
        }
        return probe
    }

    private static func nearestExistingAncestorIsListable(_ url: URL) -> Bool {
        let ancestor = nearestExistingAncestor(of: url)
        return (try? FileManager.default.contentsOfDirectory(atPath: ancestor.path)) != nil
    }

    private static func format(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .decimal          // the GB-per-hour figures elsewhere are decimal too
        f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return f.string(fromByteCount: bytes)
    }
}
