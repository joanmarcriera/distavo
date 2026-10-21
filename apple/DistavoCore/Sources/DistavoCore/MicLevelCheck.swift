// MicLevelCheck.swift — "your microphone gives no sound" early warning (Vikunja #3930).
//
// `StartLevelCheck` (#3502) only fires when BOTH channels are silent for 15 s. A call where the other
// side is audible but the microphone is dead (wrong input, muted, permission) records half a meeting
// and was found out afterwards. This check answers `true` exactly once, `window` seconds in, when the
// microphone never cleared the noise gate while the system channel did — the case the start check
// cannot see (when both are silent the start check already speaks). Fed the same once-a-second RMS
// samples as `StartLevelCheck` / `SilenceMonitor`; pure and clock-free like them.

public struct MicLevelCheck: Equatable, Sendable {
    public let window: Int
    public let gate: Float
    private var elapsed = 0
    private var systemHeard = false
    private var done = false

    public init(window: Int = 10, gate: Float = StereoBalancer.noiseGate) {
        self.window = window; self.gate = gate
    }

    /// One call per second. Returns `true` once, at the end of the window, if the mic stayed silent
    /// while system audio was heard. Any mic sound ends the check silently.
    public mutating func ingest(mic: Float, system: Float) -> Bool {
        guard !done else { return false }
        elapsed += 1
        if mic >= gate { done = true; return false }
        if system >= gate { systemHeard = true }
        if elapsed >= window { done = true; return systemHeard }
        return false
    }
}
