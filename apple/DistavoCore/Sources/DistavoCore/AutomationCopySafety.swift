import Foundation

/// Copy safety (temp naming, source checks) and URL throttling for the
/// automation entry points (#2953). Pure helpers; the app target does the I/O.

extension QueuedFile {

    /// Suffix of in-progress copies. Deliberately NOT `.part`: the recorder's
    /// startup recovery finalises any `*.wav.part` as a crashed meeting, and the
    /// scanner must never see a temp as a recording.
    public static let tempSuffix = ".distavo-copy"

    /// Hidden temp file next to `destination` ("/r/a.wav" -> "/r/.a.wav.distavo-copy").
    public static func tempURL(for destination: URL) -> URL {
        destination.deletingLastPathComponent()
            .appendingPathComponent("." + destination.lastPathComponent + tempSuffix)
    }

    /// True for our own in-progress/stale copies.
    public static func isTempName(_ name: String) -> Bool {
        name.hasPrefix(".") && name.hasSuffix(tempSuffix)
    }

    /// Delete stale temp copies left by a crash mid-copy. Returns how many.
    @discardableResult
    public static func removeStaleTemps(in dir: URL) -> Int {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return 0 }
        var n = 0
        for name in names where isTempName(name) {
            if (try? fm.removeItem(at: dir.appendingPathComponent(name))) != nil { n += 1 }
        }
        return n
    }

    /// Why a source cannot be queued.
    public enum SourceProblem: Equatable, Sendable { case notRegularFile, empty }

    /// nil when the source is fine.
    public static func sourceProblem(isRegularFile: Bool, size: Int?) -> SourceProblem? {
        if !isRegularFile { return .notRegularFile }
        if (size ?? 0) <= 0 { return .empty }
        return nil
    }

    /// Whether `file` already lives inside `folder` (symlinks resolved), so it
    /// should be scanned in place rather than duplicated.
    public static func isInside(_ file: URL, folder: URL) -> Bool {
        let f = file.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let d = folder.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        return f.count > d.count && Array(f.prefix(d.count)) == d
    }
}

/// Drops repeats of a command arriving within `interval` seconds, so a page
/// looping `location = "distavo://process-now"` cannot hammer the app.
public struct CommandThrottle: Sendable {
    public let interval: TimeInterval
    private var last: [String: TimeInterval] = [:]
    public init(interval: TimeInterval = 5) { self.interval = interval }

    /// True when the command may run now (and records it).
    public mutating func allow(_ command: AutomationCommand, now: TimeInterval) -> Bool {
        let key = String(describing: command)
        if let t = last[key], now - t < interval { return false }
        last[key] = now
        return true
    }
}
