// MicFallback.swift — automatic input fallback for the built-in recorder (Vikunja #4039).
//
// When the microphone Distavo started on never gives sound, try the next real input device, then
// the next, each once. If every one stays silent, go back to the FIRST and stay there (no endless
// cycling) and tell the user nobody is picking up sound. The policy is pure and clock-free like
// MicLevelCheck / SilenceMonitor: it is fed one mic RMS per second (through the shared
// MicSilenceSignal, so it can never disagree with the #3930 warning) plus the ids of the inputs
// that are plugged in right now, and answers with an Action.
//
// It only runs until the FIRST sound: once any input has been heard the policy ends for the
// recording, so an ordinary pause in a meeting can never move the microphone. It never touches the
// macOS default input; the app target rebuilds its private aggregate on the id it is told.
// `recording.mic_auto_switch` (RecordingOptions) gates it; the app target does not create it when off.

/// One input device as the app target reads it from Core Audio.
public struct InputDeviceInfo: Equatable, Sendable {
    public let id: String          // Core Audio device UID
    public let name: String
    public let inputChannels: Int
    public let outputChannels: Int
    public init(id: String, name: String, inputChannels: Int, outputChannels: Int = 0) {
        self.id = id; self.name = name; self.inputChannels = inputChannels; self.outputChannels = outputChannels
    }
}

public enum MicCandidates {
    /// Name fragments (lower case) of virtual loopbacks and Distavo's own aggregate: they carry
    /// other apps' audio or ours, never a person speaking, so they must not be tried.
    static let excludedNameFragments = ["blackhole", "loopback", "soundflower", "zoomaudio", "zoom audio",
                                        "microsoft teams audio", "teams audio", "distavo", "aggregate",
                                        "multi-output", "krisp", "obs virtual", "vb-cable", "ndi audio"]

    public static func isReal(_ d: InputDeviceInfo) -> Bool {
        guard d.inputChannels > 0 else { return false }
        let n = d.name.lowercased()
        return !excludedNameFragments.contains { n.contains($0) }
    }

    /// Real inputs only, the default first (when it is a real one), the rest in the system order,
    /// each id once.
    public static func ordered(devices: [InputDeviceInfo], defaultID: String?) -> [InputDeviceInfo] {
        var seen = Set<String>()
        let real = devices.filter { isReal($0) && seen.insert($0.id).inserted }
        guard let defaultID, let first = real.first(where: { $0.id == defaultID }) else { return real }
        return [first] + real.filter { $0.id != defaultID }
    }
}

public struct MicFallback: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case none
        /// The current input was silent for `window` seconds: record from this one instead.
        case switchTo(String)
        /// Every input stayed silent. `returnTo` is the first device's id when the recorder is on
        /// another one and must go back; nil when it is already on the first (or it is gone).
        case allSilent(returnTo: String?)
    }

    public let window: Int
    public let ring: [String]
    public private(set) var signal: MicSilenceSignal
    public private(set) var currentIndex = 0
    public private(set) var finished = false
    private var tried: Set<Int> = [0]

    /// `ring`: ordered device ids, the one recording at the start first. `window`: silent
    /// seconds before moving on (at least 1).
    public init(ring: [String], window: Int = 8, gate: Float = StereoBalancer.noiseGate) {
        self.ring = ring
        self.window = max(1, window)
        self.signal = MicSilenceSignal(gate: gate)
        // Nothing to switch between (0 or 1 input): the policy has nothing to do.
        self.finished = ring.count < 2
    }

    public var current: String? { ring.indices.contains(currentIndex) ? ring[currentIndex] : nil }

    /// One call per second. `available`: ids of the inputs plugged in right now.
    public mutating func ingest(mic: Float, available: Set<String>) -> Action {
        guard !finished else { return .none }
        let silent = signal.ingest(mic: mic)
        if !silent { finished = true; return .none }          // sound heard: the policy ends
        let gone = !available.contains(ring[currentIndex])     // unplugged mid-ring: move on at once
        guard signal.silentSeconds >= window || gone else { return .none }

        if let next = ring.indices.first(where: { !tried.contains($0) && available.contains(ring[$0]) }) {
            tried.insert(next)
            currentIndex = next
            signal.restartStretch()
            return .switchTo(ring[next])
        }
        finished = true
        let back = (currentIndex != 0 && available.contains(ring[0])) ? ring[0] : nil
        if back != nil { currentIndex = 0 }
        return .allSilent(returnTo: back)
    }
}
