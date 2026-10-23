// MicLevelCheck.swift — "your microphone gives no sound" early warning (Vikunja #3930).
//
// `StartLevelCheck` (#3502) only fires when BOTH channels are silent for 15 s. A call where the other
// side is audible but the microphone is dead (wrong input, muted, permission) records half a meeting
// and was found out afterwards. This check answers `true` exactly once, `window` seconds in, when the
// microphone never cleared the noise gate while the system channel did — the case the start check
// cannot see (when both are silent the start check already speaks). Fed the same once-a-second RMS
// samples as `StartLevelCheck` / `SilenceMonitor`; pure and clock-free like them.
//
// `window` comes from `mic_silence_warning_seconds` (0 = off). `ignore()` is the user's "Ignore"
// (listening-only call): it ends the check for this recording. The silence measurement itself is the
// shared `MicSilenceSignal`, also used by the input fallback (#4039).

public struct MicLevelCheck: Equatable, Sendable {
    public let window: Int
    public let gate: Float
    public private(set) var signal: MicSilenceSignal
    /// True while the warning is on screen: silent past the window and no sound since. Drives the
    /// "mic silent" menu label, which withdraws itself when sound arrives.
    public private(set) var warning = false
    private var elapsed = 0
    private var systemHeard = false
    private var done = false

    public init(window: Int = 10, gate: Float = StereoBalancer.noiseGate) {
        self.window = window; self.gate = gate
        self.signal = MicSilenceSignal(gate: gate)
    }

    /// One call per second. Returns `true` once, at the end of the window, if the mic stayed silent
    /// while system audio was heard. Any mic sound ends the check silently (and clears `warning`).
    public mutating func ingest(mic: Float, system: Float) -> Bool {
        let silent = signal.ingest(mic: mic)
        if !silent { warning = false }
        guard window > 0, !done else { return false }
        elapsed += 1
        if !silent { done = true; return false }
        if system >= gate { systemHeard = true }
        if elapsed >= window {
            done = true
            warning = systemHeard
            return systemHeard
        }
        return false
    }

    /// The user chose Ignore: no further warning for this recording, label withdrawn.
    public mutating func ignore() { done = true; warning = false }
}
