import Foundation

/// One "Benchmark this Mac" measurement (Vikunja #2160): how long a
/// downloaded engine took per minute of audio on a short fixture, and the
/// process's peak resident memory while it ran. Stored in the config so the
/// model suggestion can be measured rather than assumed from physical memory.
public struct BenchmarkResult: Codable, Equatable, Sendable {
    public var modelID: String
    /// Wall-clock seconds of compute per minute of audio (lower is faster;
    /// 60 = real time). 0 when the run failed.
    public var secondsPerAudioMinute: Double
    /// Peak resident size of the app while this model ran, in MB, if sampled.
    public var peakMemoryMB: Int?
    public var measuredAt: Date
    /// Why the run failed, or nil on success.
    public var error: String?

    enum CodingKeys: String, CodingKey {
        case modelID = "model_id", secondsPerAudioMinute = "seconds_per_audio_minute"
        case peakMemoryMB = "peak_memory_mb", measuredAt = "measured_at", error
    }

    public init(modelID: String, secondsPerAudioMinute: Double, peakMemoryMB: Int? = nil,
                measuredAt: Date = Date(), error: String? = nil) {
        self.modelID = modelID; self.secondsPerAudioMinute = secondsPerAudioMinute
        self.peakMemoryMB = peakMemoryMB; self.measuredAt = measuredAt; self.error = error
    }

    public var succeeded: Bool { error == nil && secondsPerAudioMinute > 0 }
}

/// Pure decisions over benchmark results — what the app shows and which
/// model it recommends once it has measurements. Dependency-free and tested.
public enum Benchmark {
    /// A model is "comfortable" on this Mac when a minute of audio takes at
    /// most this many seconds of compute (3x faster than real time).
    public static let comfortableSecondsPerMinute = 20.0

    /// Models that ran successfully on this Mac — these override the
    /// physical-memory gate in Settings (the measurement beats the assumption).
    public static func measuredOK(_ results: [BenchmarkResult]) -> Set<String> {
        Set(results.filter(\.succeeded).map(\.modelID))
    }

    /// The suggestion, measured when possible: the highest-quality Whisper
    /// model that ran comfortably; otherwise the fastest one that ran at all;
    /// otherwise the physical-memory rule as before.
    public static func recommended(results: [BenchmarkResult],
                                   memoryBytes: UInt64) -> EmbeddedModel {
        let ok = results.filter { $0.succeeded && EmbeddedModelCatalog.model(id: $0.modelID).engine == .whisperKit }
        let byID = Dictionary(ok.map { ($0.modelID, $0) }, uniquingKeysWith: { _, b in b })
        // Quality order for a general-purpose (English-first) suggestion.
        for id in ["large-v3-turbo", "small"] {
            if let r = byID[id], r.secondsPerAudioMinute <= comfortableSecondsPerMinute {
                return EmbeddedModelCatalog.model(id: id)
            }
        }
        if let fastest = ok.min(by: { $0.secondsPerAudioMinute < $1.secondsPerAudioMinute }) {
            return EmbeddedModelCatalog.model(id: fastest.modelID)
        }
        return EmbeddedModelCatalog.recommended(memoryBytes: memoryBytes)
    }

    /// "Measured on this Mac: Best (Whisper large-v3 turbo) 6.1 s per minute of
    /// audio, peak 2.3 GB · Fast (Parakeet) 1.8 s per minute…" — nil when
    /// nothing has been measured.
    public static func caption(_ results: [BenchmarkResult]) -> String? {
        guard !results.isEmpty else { return nil }
        let parts = results.map { r -> String in
            let name = EmbeddedModelCatalog.model(id: r.modelID).displayName
            if let error = r.error { return "\(name): failed (\(error))" }
            var s = "\(name) \(String(format: "%.1f", r.secondsPerAudioMinute)) s per minute of audio"
            if let mb = r.peakMemoryMB { s += ", peak \(String(format: "%.1f", Double(mb) / 1024)) GB" }
            return s
        }
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
        let when = results.map(\.measuredAt).max().map { f.string(from: $0) } ?? ""
        return "Measured on this Mac (\(when)): " + parts.joined(separator: " · ") + "."
    }
}
