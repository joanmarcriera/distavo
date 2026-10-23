// MeetingReminderPolicy.swift — at meeting time: remind, start automatically, or do nothing (Vikunja #4006).
//
// A stateless pure function, fake-clock tested; the controller calls it on a timer / on wake and passes the
// set of occurrences it has already acted on (`handled`), so a decision is never repeated. Nothing here
// starts a recording, posts a notification or reads the microphone.
//
// Rules:
//  - Never while already recording, never for a skipped or already-handled occurrence, never once the
//    scheduled end has passed (a Mac that woke mid-meeting still acts; one that woke after it does not).
//  - Plan `remind`: remind from `remindLead` (60 s) before the start.
//  - Plan `record`: start at the event start; with call detection on, start only once a call app holds the
//    microphone, and if no call signal arrives within `noCallFallback` (10 min) fall back to a reminder
//    rather than recording an empty room. With detection off, start at the event start.
//  - "Pause watching" holds automatic work: while paused an auto-start becomes a reminder.
import Foundation

public enum MeetingReminderPolicy {
    public enum Action: Equatable, Sendable {
        case none
        /// "<title> starts now. Record?" with a Record button.
        case remind
        /// Start recording now, then post "Recording started: <title>".
        case startRecording
    }

    public struct Context: Equatable, Sendable {
        public var now: Date
        public var isRecording: Bool
        public var isPaused: Bool
        /// Is call detection (Auto-record 2) switched on?
        public var detectionOn: Bool
        /// Does a call app / browser hold the microphone now? Only meaningful with detection on.
        public var callActive: Bool
        /// Occurrence keys already reminded or started.
        public var handled: Set<String>

        public init(now: Date, isRecording: Bool = false, isPaused: Bool = false, detectionOn: Bool = false,
                    callActive: Bool = false, handled: Set<String> = []) {
            self.now = now; self.isRecording = isRecording; self.isPaused = isPaused
            self.detectionOn = detectionOn; self.callActive = callActive; self.handled = handled
        }
    }

    public static let remindLead: TimeInterval = 60
    public static let noCallFallback: TimeInterval = 600

    public static func decide(_ c: RecordCandidate, _ ctx: Context) -> Action {
        guard !ctx.isRecording, c.plan != .skip, !ctx.handled.contains(c.occurrenceKey),
              ctx.now < c.scheduledEnd, ctx.now >= c.start - remindLead else { return .none }
        switch c.plan {
        case .skip: return .none
        case .remind: return .remind
        case .record:
            if ctx.isPaused { return .remind }
            guard ctx.now >= c.start else { return .none }
            if !ctx.detectionOn { return .startRecording }
            if ctx.callActive { return .startRecording }
            return ctx.now >= c.start + noCallFallback ? .remind : .none
        }
    }

    /// The first candidate that needs an action now, in start order, with that action.
    public static func next(_ candidates: [RecordCandidate], _ ctx: Context) -> (RecordCandidate, Action)? {
        for c in candidates.sorted(by: { ($0.start, $0.occurrenceKey) < ($1.start, $1.occurrenceKey) }) {
            let a = decide(c, ctx)
            if a != .none { return (c, a) }
        }
        return nil
    }
}
