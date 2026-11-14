import Foundation

/// The longest a built-in recording may run (Marc's requirement of 13 Nov 2026, alongside #6759): someone who
/// forgets to press Stop must not record all night. When the cap is reached the recording stops through the
/// normal stop path: what was recorded is saved and processed as usual, and the user is told the cap was
/// reached. Ten minutes before the cap a notification says it is coming, so someone still in the meeting can
/// start a new recording straight after.
///
/// Pure and clock-free: the caller feeds the elapsed time of the recording (a monotonic clock in the app, so
/// a wall-clock change can never stop or extend a take) once a second, and acts on the event. Each event
/// fires once per recording. The limit can change while recording (Settings apply live): lowering it below
/// the time already recorded stops at the next tick; 0 switches the cap off.
public struct RecordingDurationCap: Equatable, Sendable {
    /// `recording.max_duration_hours` when the key is absent, also for configs that predate it: the cap is
    /// a safety net, so it is on for everyone unless switched off.
    public static let defaultHours = 8
    /// Accepted range; 0 = no limit.
    public static let hoursRange = 0...24
    /// How long before the cap the warning comes.
    public static let warningLead: TimeInterval = 10 * 60

    public enum Event: Equatable, Sendable {
        case none
        /// The cap is `minutesLeft` minutes away.
        case warn(minutesLeft: Int)
        /// The cap is reached: stop the recording now.
        case stop(hours: Int)
    }

    /// Cap in whole hours; 0 = no limit.
    public var hours: Int {
        didSet {
            hours = Self.clamp(hours)
            // A raised limit earns a fresh warning before its own stop.
            if hours == 0 || hours > oldValue { warned = false }
        }
    }
    private var warned = false
    private var stopped = false

    public init(hours: Int = defaultHours) { self.hours = Self.clamp(hours) }

    public static func clamp(_ h: Int) -> Int { min(max(h, hoursRange.lowerBound), hoursRange.upperBound) }

    /// The limit in seconds, or nil when there is none.
    public var limit: TimeInterval? { hours > 0 ? TimeInterval(hours) * 3600 : nil }

    /// Feed the elapsed recording time (seconds); returns what to do now.
    public mutating func observe(elapsed: TimeInterval) -> Event {
        guard let limit, !stopped, elapsed.isFinite else { return .none }
        if elapsed >= limit {
            stopped = true
            return .stop(hours: hours)
        }
        // Warn once, and only when the warning still has its lead (a limit lowered to just past the elapsed
        // time stops without a warning a few seconds earlier).
        if !warned, elapsed >= limit - Self.warningLead {
            warned = true
            let left = Int(((limit - elapsed) / 60).rounded(.up))
            return left >= 1 ? .warn(minutesLeft: left) : .none
        }
        return .none
    }

    /// Notification text for the warning.
    public static func warningText(minutesLeft: Int, hours: Int) -> (title: String, body: String) {
        ("Recording stops in \(minutesLeft) min",
         "This recording reaches the \(hours)-hour limit in \(minutesLeft) minutes and will then be saved and "
            + "transcribed. Change the limit in Settings, Recording.")
    }

    /// "1 hour" / "8 hours" for the Settings stepper.
    public static func hoursLabel(_ h: Int) -> String { h == 1 ? "1 hour" : "\(h) hours" }

    /// Notification text once the cap stopped the recording.
    public static func stoppedText(hours: Int, fileName: String) -> (title: String, body: String) {
        ("Recording stopped at the \(hours)-hour limit",
         "\(fileName) was saved and Distavo will transcribe it. If the meeting is still going, start a new "
            + "recording. Change the limit in Settings, Recording.")
    }
}
