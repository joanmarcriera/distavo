// StartLevelCheck.swift — "is anything being recorded?" check for the first seconds of a recording
// (Vikunja #3502). Two phone calls were once recorded as silence (microphone in its charging case)
// and only discovered afterwards. The controller feeds it the once-a-second mic / system RMS it
// already measures for `SilenceMonitor`; it answers `true` exactly once, when the first `window`
// seconds have passed with neither channel ever clearing the noise gate. Pure and clock-free.

public struct StartLevelCheck: Equatable, Sendable {
    /// Seconds of recording after which total silence is worth saying so (long enough for a call
    /// to connect, short enough to fix and carry on).
    public let window: Int
    public let gate: Float
    private var elapsed = 0
    private var heard = false
    private var done = false

    public init(window: Int = 15, gate: Float = StereoBalancer.noiseGate) {
        self.window = window; self.gate = gate
    }

    /// One call per second of recording with the RMS of each channel. Returns `true` once, when
    /// the window is over and nothing was heard.
    public mutating func ingest(mic: Float, system: Float) -> Bool {
        guard !done else { return false }
        elapsed += 1
        if mic >= gate || system >= gate { heard = true; done = true; return false }
        if elapsed >= window { done = true; return true }
        return false
    }
}
