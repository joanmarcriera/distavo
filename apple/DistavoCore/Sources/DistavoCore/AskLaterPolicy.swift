// AskLaterPolicy.swift — "Ask me later" for the end-of-recording question (Vikunja #4020).
//
// Pure policy, no UI and no timers, so it is unit-tested with a fake clock. The app target (not wired yet:
// the sheet is still a modal NSAlert) asks `nextStep(now:)` and renders the answer.
//   - Delay choices: 5 / 15 / 60 minutes, or "after my next call" (the next recording's stop).
//   - One reminder when due, a second one if ignored, then it gives up and leaves a
//     "N meetings need names" menu item: never nag forever.
//   - Persistence: `<base>.ask-later.json` in the work dir, so a quit or relaunch keeps the answer pending.
import Foundation

public struct AskLaterEntry: Codable, Equatable, Sendable {
    public var base: String
    /// When the next reminder is due; nil while waiting for the next call to end.
    public var due: Date?
    /// Reminders already shown (0 before the first one).
    public var reminded: Int
    public var afterNextCall: Bool

    public init(base: String, due: Date?, reminded: Int = 0, afterNextCall: Bool = false) {
        self.base = base; self.due = due; self.reminded = reminded; self.afterNextCall = afterNextCall
    }
}

public enum AskLaterChoice: Equatable, Sendable {
    case minutes(Int)       // 5, 15 or 60
    case afterNextCall
}

public enum AskLaterStep: Equatable, Sendable {
    case wait
    case remind
    /// Reminders are used up: show "N meetings need names" in the menu instead.
    case leaveInMenu
}

public enum AskLaterPolicy {
    public static let defaultMinutes = 15
    /// First reminder plus one repeat.
    public static let maxReminders = 2
    /// Gap before the repeat reminder.
    public static let repeatInterval: TimeInterval = 30 * 60

    public static func start(base: String, choice: AskLaterChoice, now: Date) -> AskLaterEntry {
        switch choice {
        case .minutes(let m):
            return AskLaterEntry(base: base, due: now.addingTimeInterval(Double(max(1, m)) * 60))
        case .afterNextCall:
            return AskLaterEntry(base: base, due: nil, afterNextCall: true)
        }
    }

    /// The next recording ended: an "after my next call" entry becomes due now.
    public static func nextCallEnded(_ e: AskLaterEntry, now: Date) -> AskLaterEntry {
        guard e.afterNextCall, e.due == nil else { return e }
        var c = e; c.due = now; return c
    }

    public static func nextStep(_ e: AskLaterEntry, now: Date) -> AskLaterStep {
        if e.reminded >= maxReminders { return .leaveInMenu }
        guard let due = e.due else { return .wait }
        return now >= due ? .remind : .wait
    }

    /// A reminder was shown: count it and schedule the repeat.
    public static func reminded(_ e: AskLaterEntry, now: Date) -> AskLaterEntry {
        var c = e
        c.reminded += 1
        c.due = now.addingTimeInterval(repeatInterval)
        return c
    }

    /// Entries that still need names: the count for the menu item.
    public static func needingNames(_ entries: [AskLaterEntry]) -> Int { entries.count }

    // MARK: persistence

    public static func fileURL(workDir: URL, base: String) -> URL {
        workDir.appendingPathComponent("\(base).ask-later.json")
    }

    public static func save(_ e: AskLaterEntry, workDir: URL) throws {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try enc.encode(e).write(to: fileURL(workDir: workDir, base: e.base), options: .atomic)
    }

    public static func load(workDir: URL, base: String) -> AskLaterEntry? {
        guard let d = try? Data(contentsOf: fileURL(workDir: workDir, base: base)) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(AskLaterEntry.self, from: d)
    }

    public static func remove(workDir: URL, base: String) {
        try? FileManager.default.removeItem(at: fileURL(workDir: workDir, base: base))
    }
}
