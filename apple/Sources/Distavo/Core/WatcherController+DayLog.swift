import AppKit
import DistavoCore

// "Write Today's Day Log" (D102, drive 2026-11-23): `notes/day-logs/YYYY-MM-DD-day.md` from that day's notes.
// Triggered from the menu and by `distavo://daylog?date=YYYY-MM-DD`. Everything the file says is decided by
// `DayLog` (DistavoCore); this file only resolves the folders, writes off the main actor and opens the result.
extension WatcherController {

    /// `date` nil = today. Writes, then opens the day log in the default Markdown app.
    func writeDayLog(isoDate: String? = nil, fromLink: Bool = false) {
        let zone = TimeZone.current
        let day: Date
        if let isoDate {
            guard let parsed = DayLog.date(fromISO: isoDate, timeZone: zone) else { return }
            day = parsed
        } else {
            day = Date()
        }
        let notes = Config.resolvePath(config.notesDir), work = Config.resolvePath(config.workDir)
        Task {
            let result: Result<URL, Error> = await Task.detached(priority: .userInitiated) {
                Result { try DayLog.write(day: day, notesDir: notes, workDir: work, timeZone: zone, onlyIfMissing: fromLink) }
            }.value
            switch result {
            case .success(let url):
                self.log("Day log written: \(url.lastPathComponent)")
                NSWorkspace.shared.open(url)
            case .failure(let error):
                self.log("Day log could not be written: \(error.localizedDescription)")
            }
        }
    }
}
