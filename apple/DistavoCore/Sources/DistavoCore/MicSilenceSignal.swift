// MicSilenceSignal.swift — the ONE "is the microphone silent?" measurement (Vikunja #3930, #4039).
//
// Both the early warning (`MicLevelCheck`, #3930) and the automatic input fallback (`MicFallback`,
// #4039) need to know how long the microphone has been below the noise gate. They share this
// value so they can never disagree. Fed one mic RMS per second; pure and clock-free.
// A NaN or negative sample counts as silence (a broken meter must not look like sound).

public struct MicSilenceSignal: Equatable, Sendable {
    public let gate: Float
    /// Consecutive seconds the mic has been below the gate (0 once sound arrives).
    public private(set) var silentSeconds = 0
    /// True once the mic has cleared the gate at least once in this recording.
    public private(set) var everHeard = false

    public init(gate: Float = StereoBalancer.noiseGate) { self.gate = gate }

    /// One call per second. Returns whether the mic is currently silent.
    @discardableResult
    public mutating func ingest(mic: Float) -> Bool {
        if mic >= gate { silentSeconds = 0; everHeard = true; return false }
        silentSeconds += 1
        return true
    }

    /// Forget the current silent stretch (e.g. after the input device was switched) without
    /// forgetting that sound was heard earlier.
    public mutating func restartStretch() { silentSeconds = 0 }
}
