import Foundation
import AVFoundation

/// Long recordings are transcribed in bounded parts (Vikunja #6759).
///
/// A 4 h 21 min recording aborted Distavo inside CoreML twice and then on every relaunch: every engine loads
/// the whole file as one float array (WhisperKit, the dropped-speech pass and SpeakerKit each hold a copy, so
/// memory and the CoreML buffers grew with the length of the meeting). The same audio cut into 20-minute
/// pieces transcribed without a crash. So a converted work WAV longer than `thresholdSeconds` is cut into
/// parts of about `partSeconds`, each part goes through the ordinary `transcribe` dependency (any engine),
/// and the parts' results are stitched back into one WhisperX-shaped result with absolute timestamps.
///
/// - Cuts land on the quietest second within `searchSeconds` of each nominal boundary, so a word is rarely
///   split in two.
/// - A part with (almost) no sound is not sent to an engine at all: forgotten recordings are mostly silence.
/// - Each finished part is cached beside the work files (`<base>.part-NN.json`, keyed to the work WAV's size
///   and date), so a deferral, a quit or a crash resumes at the next part instead of starting again. The
///   caches go once the note is written (`removeCaches`).
/// - Only the part files and one part's result are in memory at a time; the work WAV is read in 64k-frame
///   buffers (`RecordingSplit.windowRMS`, `RecordingSplit.cut`).
///
/// Speaker labels come from a diariser that only ever saw one part, so they are renumbered per part by talk
/// time (the person who spoke most is `SPEAKER_00`); the note's footer says so, because two people can swap
/// labels at a part boundary. Shorter recordings never come here and are transcribed exactly as before.
public enum LongRecording {

    /// Work WAVs longer than this are transcribed in parts (90 min: the longest takes seen working whole
    /// were 61 and 84 minutes; the crash was at 4 h 21 min).
    public static let thresholdSeconds: Double = 90 * 60
    /// Nominal part length.
    public static let partSeconds: Double = 30 * 60
    /// How far either side of a nominal boundary to look for the quietest second.
    public static let searchSeconds: Double = 60
    /// A trailing remainder shorter than this joins the part before it.
    public static let minimumTailSeconds: Double = 5 * 60
    /// The longest part `plan` can make: a middle part ends at most `searchSeconds` past its nominal boundary,
    /// and the last part absorbs a remainder shorter than `minimumTailSeconds`. 35 minutes.
    public static let maxPartSeconds: Double = partSeconds + max(searchSeconds, minimumTailSeconds)
    /// A part with fewer sounding seconds than this is silent and skipped.
    public static let minimumSoundingSeconds = 3

    /// One part of the recording, in seconds of the work WAV.
    public struct Part: Equatable, Codable, Sendable {
        public var index: Int
        public var start: Double
        public var end: Double
        /// Fewer than `minimumSoundingSeconds` seconds above the noise gate: not worth an engine run.
        public var isSilent: Bool
        public var duration: Double { end - start }
    }

    // MARK: Planning (pure)

    /// The parts for a recording of `duration` seconds, from its per-second loudness (`windowRMS[i]` = second i,
    /// as `RecordingSplit.windowRMS` measures it). Empty when the recording is not long enough to need parts.
    public static func plan(windowRMS: [Float], duration: Double,
                            threshold: Double = thresholdSeconds, part: Double = partSeconds,
                            search: Double = searchSeconds, minimumTail: Double = minimumTailSeconds,
                            gate: Float = StereoBalancer.noiseGate) -> [Part] {
        guard duration > threshold, part > 0 else { return [] }
        var cuts: [Double] = []
        var previous = 0.0
        var nominal = part
        while nominal < duration - minimumTail {
            // Search the window around the nominal boundary, but never so early that a part would be shorter
            // than half a part, and never past the point that leaves less than the minimum tail.
            let low = max(previous + part / 2, nominal - search)
            let high = min(duration - minimumTail, nominal + search)
            let cut = high > low ? quietestSecond(windowRMS, from: low, to: high) : nominal
            cuts.append(cut)
            previous = cut
            nominal = cut + part
        }
        var parts: [Part] = []
        var start = 0.0
        for (i, end) in (cuts + [duration]).enumerated() {
            parts.append(Part(index: i, start: start, end: end,
                              isSilent: soundingSeconds(windowRMS, from: start, to: end, gate: gate) < minimumSoundingSeconds))
            start = end
        }
        return parts
    }

    /// The start of the quietest one-second window in `[from, to]` (the earliest on a tie), in seconds.
    static func quietestSecond(_ rms: [Float], from: Double, to: Double) -> Double {
        let lo = max(0, Int(from.rounded(.up)))
        let hi = min(rms.count - 1, Int(to.rounded(.down)))
        guard lo <= hi else { return from }
        var best = lo
        for i in lo...hi where rms[i] < rms[best] { best = i }
        return Double(best)
    }

    static func soundingSeconds(_ rms: [Float], from: Double, to: Double, gate: Float) -> Int {
        let lo = max(0, Int(from))
        let hi = min(rms.count, Int(to.rounded(.up)))
        guard lo < hi else { return 0 }
        return rms[lo..<hi].reduce(0) { $0 + ($1 > gate ? 1 : 0) }
    }

    // MARK: Stitching (pure)

    /// What one part produced: its result (nil = skipped as silent, or no speech), or why it failed.
    public struct PartOutcome {
        public var part: Part
        public var result: [String: Any]?
        public var failure: String?
        public init(part: Part, result: [String: Any]?, failure: String? = nil) {
            self.part = part; self.result = result; self.failure = failure
        }
    }

    /// One WhisperX-shaped result from the parts, in order: timestamps shifted to the whole recording,
    /// speakers renumbered per part by talk time, detections weighted by each part's speech, footer notes
    /// merged (duplicates dropped) plus the lines saying the recording was transcribed in parts and which
    /// part, if any, is missing. Keys the stitcher does not know are taken from the first part that has them.
    public static func stitch(_ outcomes: [PartOutcome]) -> [String: Any] {
        var out: [String: Any] = [:]
        var segments: [[String: Any]] = []
        var engines: [String] = [], languagesUsed: [String] = [], notes: [String] = []
        var weighted: [String: Double] = [:]
        var speechTotal = 0.0
        for outcome in outcomes {
            guard let result = outcome.result else { continue }
            let offset = outcome.part.start
            let partSegments = (result["segments"] as? [[String: Any]]) ?? []
            let names = speakerRenumbering(partSegments)
            var speech = 0.0
            for var seg in partSegments {
                let s = (seg["start"] as? Double) ?? 0, e = (seg["end"] as? Double) ?? s
                speech += max(0, e - s)
                seg["start"] = s + offset
                seg["end"] = e + offset
                if let spk = seg["speaker"] as? String, let renamed = names[spk] { seg["speaker"] = renamed }
                if let words = seg["words"] as? [[String: Any]] {
                    seg["words"] = words.map { w in
                        var w = w
                        if let ws = w["start"] as? Double { w["start"] = ws + offset }
                        if let we = w["end"] as? Double { w["end"] = we + offset }
                        return w
                    }
                }
                segments.append(seg)
            }
            for d in (result["detections"] as? [[String: Any]]) ?? [] {
                guard let code = d["code"] as? String else { continue }
                weighted[code, default: 0] += ((d["probability"] as? Double) ?? 0) * max(speech, 1)
            }
            if (result["detections"] as? [[String: Any]])?.isEmpty == false { speechTotal += max(speech, 1) }
            if let e = result["engine"] as? String, !engines.contains(e) { engines.append(e) }
            if let l = result["language_used"] as? String, !languagesUsed.contains(l) { languagesUsed.append(l) }
            for n in (result["footer_notes"] as? [String]) ?? [] where !notes.contains(n) { notes.append(n) }
            for (key, value) in result where out[key] == nil
                && !["segments", "detections", "engine", "language_used", "footer_notes"].contains(key) {
                out[key] = value
            }
        }
        out["segments"] = segments
        if !weighted.isEmpty, speechTotal > 0 {
            out["detections"] = weighted.sorted { $0.value > $1.value }
                .map { ["code": $0.key, "probability": $0.value / speechTotal] as [String: Any] }
        }
        if !engines.isEmpty { out["engine"] = engines.joined(separator: " + ") }
        if !languagesUsed.isEmpty { out["language_used"] = languagesUsed.joined(separator: ", ") }
        notes.append(partsFooterLine(outcomes.map(\.part)))
        for o in outcomes { if let why = o.failure { notes.append(missingPartLine(o.part, reason: why)) } }
        out["footer_notes"] = notes
        return out
    }

    /// Per-part speaker labels -> `SPEAKER_00`, `SPEAKER_01`, ... in order of talk time (ties: label order).
    static func speakerRenumbering(_ segments: [[String: Any]]) -> [String: String] {
        var talk: [String: Double] = [:]
        for seg in segments {
            guard let spk = seg["speaker"] as? String else { continue }
            let s = (seg["start"] as? Double) ?? 0, e = (seg["end"] as? Double) ?? s
            talk[spk, default: 0] += max(0, e - s)
        }
        let order = talk.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
        var map: [String: String] = [:]
        for (i, spk) in order.enumerated() { map[spk] = String(format: "SPEAKER_%02d", i) }
        return map
    }

    static func partsFooterLine(_ parts: [Part]) -> String {
        let silent = parts.filter(\.isSilent).count
        return "This recording is longer than \(Int(thresholdSeconds / 60)) minutes, so it was transcribed in "
            + "\(parts.count) parts of about \(Int(partSeconds / 60)) minutes"
            + (silent > 0 ? " (\(silent) silent, skipped)" : "")
            + ". Speaker labels are matched between parts by how much each person spoke and can swap at a part boundary."
    }

    static func missingPartLine(_ part: Part, reason: String) -> String {
        "Part \(part.index + 1) (\(clock(part.start))-\(clock(part.end))) could not be transcribed and is missing "
            + "from the transcript: \(reason)"
    }

    /// "1:05:00" style offset.
    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }

    // MARK: Driver (AVFoundation + files)

    /// The parts for the work WAV at `wav`, or [] when it is short, unreadable or not a file (tests that inject
    /// a fake converter write no WAV, so they keep the whole-file path).
    public static func plan(wav: URL) -> [Part] {
        guard let file = try? AVAudioFile(forReading: wav) else { return [] }
        let rate = file.processingFormat.sampleRate
        guard rate > 0, Double(file.length) / rate > thresholdSeconds,
              let measured = try? RecordingSplit.windowRMS(of: wav) else { return [] }
        return plan(windowRMS: measured.rms, duration: measured.duration)
    }

    /// Transcribes `parts` of `wav` one at a time through `transcribe`, reusing cached parts, and returns the
    /// stitched result. A part that hears nothing yields no segments; a part that fails for a reason that is
    /// not a retryable dependency is recorded and the rest carry on (a missing half hour beats losing four
    /// hours); a retryable error or a cancellation stops the run with the finished parts cached. When no part
    /// produced any segment and one failed, the first failure is rethrown, as a whole-file run would have.
    public static func transcribe(
        wav: URL, parts: [Part], base: String, workDir: URL, config: TranscribeConfig,
        transcribe: (URL, TranscribeConfig) async throws -> [String: Any],
        log: (String) -> Void = { print("[Distavo] \($0)") }
    ) async throws -> [String: Any] {
        let key = WavKey(wav)
        var outcomes: [PartOutcome] = []
        var firstError: Error?
        log("long recording \(base): \(parts.count) parts of about \(Int(partSeconds / 60)) min")
        for part in parts {
            try Task.checkCancellation()
            if part.isSilent { outcomes.append(PartOutcome(part: part, result: nil)); continue }
            if let cached = loadCache(workDir: workDir, base: base, part: part, key: key) {
                outcomes.append(PartOutcome(part: part, result: cached)); continue
            }
            let partWav = workDir.appendingPathComponent("\(base).part-\(String(format: "%02d", part.index + 1)).wav")
            defer { try? FileManager.default.removeItem(at: partWav) }
            try RecordingSplit.cut(source: wav, range: part.start...part.end, destination: partWav)
            log("long recording \(base): part \(part.index + 1)/\(parts.count) (\(clock(part.start))-\(clock(part.end)))")
            do {
                let result = try await transcribe(partWav, config)
                outcomes.append(PartOutcome(part: part, result: result))
                saveCache(result, workDir: workDir, base: base, part: part, key: key)
            } catch is CancellationError {
                throw CancellationError()
            } catch let retry as RetryableDependencyError {
                throw retry
            } catch let empty as EmptyTranscriptSignal where empty.isEmptyTranscript {
                let none: [String: Any] = ["segments": [[String: Any]]()]
                outcomes.append(PartOutcome(part: part, result: none))
                saveCache(none, workDir: workDir, base: base, part: part, key: key)
            } catch {
                let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                log("long recording \(base): part \(part.index + 1) failed: \(reason)")
                if firstError == nil { firstError = error }
                outcomes.append(PartOutcome(part: part, result: nil, failure: reason))
            }
        }
        let stitched = stitch(outcomes)
        if let firstError, ((stitched["segments"] as? [[String: Any]]) ?? []).isEmpty { throw firstError }
        return stitched
    }

    // MARK: Part caches

    /// Identifies the work WAV a cache was made from: a re-conversion (new date or size) invalidates it.
    struct WavKey: Equatable {
        var size: Int
        var modified: Double
        init(size: Int, modified: Double) { self.size = size; self.modified = modified }
        init(_ url: URL) {
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            size = (attrs?[.size] as? Int) ?? -1
            modified = ((attrs?[.modificationDate] as? Date) ?? .distantPast).timeIntervalSince1970
        }
    }

    static func cacheURL(workDir: URL, base: String, part: Part) -> URL {
        workDir.appendingPathComponent("\(base).part-\(String(format: "%02d", part.index + 1)).json")
    }

    static func saveCache(_ result: [String: Any], workDir: URL, base: String, part: Part, key: WavKey) {
        let envelope: [String: Any] = ["wav_size": key.size, "wav_modified": key.modified,
                                       "start": part.start, "end": part.end, "result": result]
        // Best effort: a result that is not plain JSON (or a full disk) only costs the resume.
        guard JSONSerialization.isValidJSONObject(envelope),
              let data = try? JSONSerialization.data(withJSONObject: envelope) else { return }
        try? data.write(to: cacheURL(workDir: workDir, base: base, part: part), options: .atomic)
    }

    static func loadCache(workDir: URL, base: String, part: Part, key: WavKey) -> [String: Any]? {
        guard let data = try? Data(contentsOf: cacheURL(workDir: workDir, base: base, part: part)),
              let env = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (env["wav_size"] as? Int) == key.size,
              let modified = env["wav_modified"] as? Double, abs(modified - key.modified) < 0.001,
              let start = env["start"] as? Double, abs(start - part.start) < 0.001,
              let end = env["end"] as? Double, abs(end - part.end) < 0.001 else { return nil }
        return env["result"] as? [String: Any]
    }

    /// Removes every part cache and leftover part WAV of `base` (after the note is written).
    public static func removeCaches(workDir: URL, base: String) {
        let prefix = "\(base).part-"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: workDir.path)) ?? []
        for name in names where name.hasPrefix(prefix) && (name.hasSuffix(".json") || name.hasSuffix(".wav")) {
            let middle = name.dropFirst(prefix.count).dropLast(name.hasSuffix(".json") ? 5 : 4)
            guard middle.count == 2, middle.allSatisfy(\.isNumber) else { continue }
            try? FileManager.default.removeItem(at: workDir.appendingPathComponent(name))
        }
    }
}
