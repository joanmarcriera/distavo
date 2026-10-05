import Foundation
import DistavoCore

/// What happens to a finished built-in recording when a calendar event matches
/// (Vikunja #2946). Called by `MeetingCaptureController.stop` while the take is
/// still a `.part` (invisible to the folder scanner), so the sidecar move and the
/// rename are complete before processing can possibly start. Everything decided
/// here is pure DistavoCore logic; this file only does the file-system steps and
/// reads the calendar through `CalendarEventProviding`.
enum CalendarRecordingStep {

    /// Whether a lookup is worth waiting for: feature on and access already granted
    /// (this never prompts).
    static func wantsLookup(config: Config,
                            provider: CalendarEventProviding = EventKitCalendarProvider.shared) -> Bool {
        config.calendar.enabled && provider.access == .granted
    }

    /// The event overlapping `[start, now]`, or nil when nothing qualifies or the
    /// store does not answer within `timeout` seconds (a slow Exchange/CalDAV
    /// account must never hang Stop: the recording then keeps its name). The
    /// EventKit call runs off the main thread.
    static func lookup(start: Date, config: Config, timeout: TimeInterval = 3,
                       provider: CalendarEventProviding = EventKitCalendarProvider.shared) async -> CalendarMatch? {
        guard wantsLookup(config: config, provider: provider) else { return nil }
        let end = Date()
        let calendars = config.calendar.calendars, owner = config.noteOwner
        return await withCheckedContinuation { (cont: CheckedContinuation<CalendarMatch?, Never>) in
            let once = Once(cont)
            DispatchQueue.global(qos: .userInitiated).async {
                once.resume(CalendarMatcher.best(
                    recordingStart: start, recordingEnd: end,
                    candidates: provider.candidates(from: start, to: end),
                    calendarIDs: calendars, ownerName: owner))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { once.resume(nil) }
        }
    }

    /// Resumes a continuation exactly once, whichever of lookup / timeout comes first.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var cont: CheckedContinuation<CalendarMatch?, Never>?
        init(_ cont: CheckedContinuation<CalendarMatch?, Never>) { self.cont = cont }
        func resume(_ value: CalendarMatch?) {
            lock.lock(); let c = cont; cont = nil; lock.unlock()
            c?.resume(returning: value)
        }
    }

    /// Persist the match, optionally rename the recording and move its sidecars,
    /// and (window disabled) write the attendees as speaker hints. Returns the
    /// URL the finished recording will have (the original when not renamed or
    /// when anything failed, in which case everything stays under the old name).
    @MainActor
    static func apply(_ match: CalendarMatch, recording: URL, start: Date, config: Config,
                      recordingsDir: URL, askingSpeakers: Bool, log: (String) -> Void) -> URL {
        let workDir = Config.resolvePath(config.workDir)
        let notesDir = Config.resolvePath(config.notesDir)
        var final = recording
        var base = DistavoState.baseFor(recordingsDir: recordingsDir, path: recording)
        do { try CalendarMatchStore.save(match, workDir: workDir, base: base) }
        catch { log("Could not save the calendar match for \(recording.lastPathComponent): \(error.localizedDescription)") }

        if config.calendar.renameRecordings {
            if let renamed = CalendarRename.prepare(
                recording: recording, match: match, recordingStart: start,
                recordingsDir: recordingsDir, workDir: workDir, notesDir: notesDir) {
                final = renamed
                base = DistavoState.baseFor(recordingsDir: recordingsDir, path: renamed)
                log("Recording named after calendar event: \(renamed.lastPathComponent)")
            } else {
                log("Calendar event \"\(match.title)\" matched, but the recording keeps its name (no usable or free name)")
            }
        }

        // No "Who was in this meeting?" window: the attendees are the hints,
        // unless the owner already gave some.
        if !askingSpeakers, config.calendar.attendeesAsParticipants, !match.attendees.isEmpty,
           SpeakerHints.load(workDir: workDir, base: base) == nil {
            do { try SpeakerHints(participants: CalendarAttendees.hintsText(match.attendees)).save(workDir: workDir, base: base) }
            catch { log("Could not save the attendees as speaker hints: \(error.localizedDescription)") }
        }
        log("Calendar event matched: \"\(match.title)\" (\(match.attendees.count) attendees)")
        return final
    }

    /// After the speakers window: keep only the attendees the owner left in the
    /// participants (Skip or blank = none), so processing does not re-add names
    /// the owner removed. The match keeps its title either way.
    @MainActor
    static func pruneAttendees(recording: URL, recordingsDir: URL, config: Config) {
        let workDir = Config.resolvePath(config.workDir)
        let base = DistavoState.baseFor(recordingsDir: recordingsDir, path: recording)
        guard var match = CalendarMatchStore.load(workDir: workDir, base: base), !match.attendees.isEmpty else { return }
        let kept = CalendarAttendees.mentioned(
            in: SpeakerHints.load(workDir: workDir, base: base)?.participants, attendees: match.attendees)
        guard kept != match.attendees else { return }
        match.attendees = kept
        try? CalendarMatchStore.save(match, workDir: workDir, base: base)
    }
}
