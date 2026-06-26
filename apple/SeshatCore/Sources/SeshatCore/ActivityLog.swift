import Foundation

/// A timestamped, append-only activity log the user can read ("what was
/// processed, and when"). Persists to ~/Library/Logs/Seshat/seshat.log and
/// keeps recent lines available for in-app display.
public final class ActivityLog {
    public let url: URL
    private let queue = DispatchQueue(label: "es.joanmarcriera.seshat.activitylog")
    private let formatter: DateFormatter

    public init(url: URL = ActivityLog.defaultURL) {
        self.url = url
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        self.formatter = formatter
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Seshat/seshat.log")
    }

    /// Format a single line without writing it (testable).
    public func line(_ message: String, at date: Date = Date()) -> String {
        "[\(formatter.string(from: date))] \(message)"
    }

    /// Append a timestamped line; returns the formatted entry.
    @discardableResult
    public func append(_ message: String, at date: Date = Date()) -> String {
        let entry = line(message, at: date)
        queue.sync {
            let data = Data((entry + "\n").utf8)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(data)
            } else {
                try? data.write(to: url)
            }
        }
        return entry
    }

    /// The most recent `count` lines (oldest first).
    public func recent(_ count: Int = 50) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        return Array(lines.suffix(count))
    }
}
