import Foundation

// "Send to Reminders" decision logic (Vikunja #2941). EventKit itself lives in
// the app target behind `ReminderSink`; what to create and how to avoid
// duplicates is decided here so it is unit-tested with a fake.

/// One reminder to create.
public struct NewReminder: Equatable, Sendable {
    public var title: String
    /// Calendar day only (EventKit `dueDateComponents`); nil when the item has no parsed due date.
    public var due: DateComponents?
    /// Meeting title plus the note's file URL (with `#L<line>`).
    public var notes: String
}

public enum ReminderAccess: Equatable, Sendable { case granted, denied }

/// The EventKit seam. `requestAccess` is called lazily - only when the user
/// asks to export something that is not already exported - never at launch.
public protocol ReminderSink {
    func requestAccess() async -> ReminderAccess
    func create(_ reminder: NewReminder) throws
}

public enum RemindersExportOutcome: Equatable, Sendable {
    case exported(created: Int, alreadySent: Int)
    case accessDenied
    case failed(String)
}

/// Item ids already sent, kept in a small JSON sidecar in the work dir.
public struct RemindersLedger: Codable, Equatable, Sendable {
    public var sent: Set<String> = []
    public static let fileName = "reminders-exported.json"

    public static func load(workDir: URL) -> RemindersLedger {
        guard let d = try? Data(contentsOf: workDir.appendingPathComponent(fileName)),
              let l = try? JSONDecoder().decode(RemindersLedger.self, from: d) else { return RemindersLedger() }
        return l
    }

    public func save(workDir: URL) throws {
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: workDir.appendingPathComponent(Self.fileName), options: .atomic)
    }
}

public enum RemindersExport {

    /// The reminder for one item.
    public static func reminder(for item: ActionItem, noteTitle: String) -> NewReminder {
        var due: DateComponents?
        if let d = item.due {
            let p = d.split(separator: "-").compactMap { Int($0) }
            if p.count == 3 { due = DateComponents(year: p[0], month: p[1], day: p[2]) }
        }
        var notes = noteTitle.isEmpty ? "" : "Meeting: \(noteTitle)\n"
        notes += item.sourceLink.absoluteString
        if let o = item.owner { notes += "\nOwner: \(o)" }
        return NewReminder(title: item.title, due: due, notes: notes)
    }

    /// Exports the open `items` that are not in the ledger yet (ticked items are
    /// skipped). Asks for access only when there is something to create. Each
    /// successfully created item is recorded in the ledger saved to `workDir`.
    public static func export(items: [ActionItem], noteTitle: String, sink: ReminderSink,
                              workDir: URL) async -> RemindersExportOutcome {
        var ledger = RemindersLedger.load(workDir: workDir)
        let open = items.filter { !$0.isDone }
        let fresh = open.filter { !ledger.sent.contains($0.id) }
        let already = open.count - fresh.count
        if fresh.isEmpty { return .exported(created: 0, alreadySent: already) }
        guard await sink.requestAccess() == .granted else { return .accessDenied }
        var created = 0
        defer { try? ledger.save(workDir: workDir) }
        for item in fresh {
            do {
                try sink.create(reminder(for: item, noteTitle: noteTitle))
                ledger.sent.insert(item.id)
                created += 1
            } catch {
                return .failed("Reminders: \(error.localizedDescription) (\(created) created before the error)")
            }
        }
        return .exported(created: created, alreadySent: already)
    }
}
