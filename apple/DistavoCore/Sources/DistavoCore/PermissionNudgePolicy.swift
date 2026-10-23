// PermissionNudgePolicy.swift — what to say when a take has no system audio (Vikunja #4022).
//
// Before: Save on the end-of-recording sheet opened System Settings by itself after about every other
// meeting, because a quiet call, a phone call or a silence stop all look like "no system audio".
// Now Distavo never opens System Settings unasked; this pure policy only decides the NOTICE text:
//   - a silence stop is expected to end a quiet recording -> no permission talk at all;
//   - the permission hint is shown at most once per 24 h (the notice still appears, with plain wording);
//   - the hint is skipped when the microphone heard nothing either (a dead take is not a permission case
//     for system audio) -> plain wording.
import Foundation

public enum PermissionNudgePolicy {
    public enum Notice: Equatable, Sendable {
        /// "Distavo heard nothing from the call" + how to enable the permission.
        case permissionHint
        /// "Distavo heard nothing from the call" + "tick in person if it was".
        case plain
    }

    /// Minimum gap between two permission hints.
    public static let minimumInterval: TimeInterval = 24 * 3600

    public static func notice(stoppedBySilence: Bool, microphoneHeard: Bool,
                              lastHint: Date?, now: Date) -> Notice {
        if stoppedBySilence || !microphoneHeard { return .plain }
        if let lastHint, now.timeIntervalSince(lastHint) < minimumInterval { return .plain }
        return .permissionHint
    }

    public static func title(_ n: Notice) -> String { "Recording saved — Distavo heard nothing from the call" }

    public static func body(_ n: Notice) -> String {
        switch n {
        case .permissionHint:
            return "If you expected call audio, check System Settings → Privacy & Security → "
                + "Screen & System Audio Recording. Distavo will not open it for you."
        case .plain:
            return "Nothing came from the other side. For an in-person meeting or a phone call this is normal."
        }
    }
}
