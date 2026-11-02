import Foundation

/// What startup recovery does with a leftover `<name>.wav.part` (trust memo
/// row 3), decided from file sizes alone so it can be tested without audio.
///
/// A crash mid-finalise can leave a truncated `<name>.wav` (a 44-byte header,
/// a half-written balanced copy) next to the complete `.part`. The old rule
/// "a `.wav` exists, so the `.part` is a duplicate" then deleted the only
/// complete take. The rule now: never delete the larger file. A `.part`
/// larger than the WAV is promoted over it; a WAV at least as large as the
/// `.part` is kept and the `.part` discarded; when the `.part` cannot be
/// measured both are left alone.
/// Called from `MeetingRecorder.recoverOrphanedRecordings` in the app target.
public enum OrphanPartRecovery: Equatable {
    /// Finalise the `.part` into the WAV name (replacing a smaller WAV).
    case promotePart
    /// The WAV is complete; delete the `.part`.
    case discardPart
    /// Touch nothing.
    case keepBoth

    /// `wavSize` nil = no final WAV on disk; `partSize` nil = unreadable.
    public static func decide(wavSize: Int?, partSize: Int?) -> OrphanPartRecovery {
        guard let partSize else { return .keepBoth }
        guard let wavSize else { return .promotePart }
        return partSize > wavSize ? .promotePart : .discardPart
    }
}
