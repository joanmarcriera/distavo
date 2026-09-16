import Foundation
import AVFoundation
import DistavoCore
import DistavoEmbedded

/// "Benchmark this Mac" (Vikunja #2160): time every downloaded built-in engine
/// on a ~30 s fixture and sample the app's peak resident memory while each
/// one runs. Results go into the config (`Config.benchmark`) so the model
/// suggestion in Settings is measured, not assumed from physical memory.
///
/// The fixture is the first 30 s of the newest converted recording in the
/// work dir (real speech, already 16 kHz mono, never leaves this Mac); with
/// nothing there yet, a spoken paragraph is synthesised on-device with
/// `AVSpeechSynthesizer` — no audio is bundled with the app.
enum BenchmarkRunner {
    static let fixtureSeconds: Double = 30

    /// Every catalog model already on disk, in catalog order. Models are
    /// never downloaded by a benchmark.
    static func downloadedModels() -> [EmbeddedModel] {
        EmbeddedModelCatalog.models.filter { EmbeddedModelStore.isDownloaded($0) }
    }

    /// Run each model once under the coordinator's exclusive lock (the
    /// transcribers take it themselves) and report progress through it.
    static func run(models: [EmbeddedModel], workDir: URL, baseConfig: TranscribeConfig) async -> [BenchmarkResult] {
        var results: [BenchmarkResult] = []
        let fixture: URL
        let audioSeconds: Double
        do {
            fixture = try await makeFixture(workDir: workDir)
            audioSeconds = AudioConverter.durationSeconds(of: fixture) ?? fixtureSeconds
        } catch {
            return models.map {
                BenchmarkResult(modelID: $0.id, secondsPerAudioMinute: 0,
                                error: "no fixture: \(error.localizedDescription)")
            }
        }
        var config = baseConfig
        config.diarize = false   // measure the engine, not the diariser
        for (i, model) in models.enumerated() {
            // Two passes, keep the faster: the first pass on a 30 s fixture is
            // dominated by Core ML's one-time model specialisation, which a
            // real recording never pays again on this Mac; the second pass is
            // what every later meeting costs (the model is still loaded per
            // call — that load is included, only the compile is not).
            var best: BenchmarkResult?
            for pass in 1...2 {
                await ModelCoordinator.shared.report(
                    "Benchmark \(i + 1) of \(models.count): \(model.displayName) (pass \(pass) of 2)…")
                let sampler = MemorySampler()
                sampler.start()
                let started = Date()
                var error: String?
                do {
                    switch model.engine {
                    case .whisperKit:
                        _ = try await EmbeddedTranscriber.shared.transcribe(
                            wavURL: fixture, model: model, languageHint: "en", config: config)
                    case .parakeet:
                        _ = try await ParakeetTranscriber.shared.transcribe(
                            wavURL: fixture, languageHint: "en", config: config)
                    }
                } catch let e {
                    error = (e as? LocalizedError)?.errorDescription ?? "\(e)"
                }
                let elapsed = Date().timeIntervalSince(started)
                let peak = sampler.stop()
                let result = BenchmarkResult(
                    modelID: model.id,
                    secondsPerAudioMinute: error == nil ? elapsed / (audioSeconds / 60) : 0,
                    peakMemoryMB: peak > 0 ? Int(peak / (1024 * 1024)) : nil,
                    error: error)
                if error != nil { best = result; break }   // no point in a second pass
                if best == nil || result.secondsPerAudioMinute < best!.secondsPerAudioMinute { best = result }
            }
            if let best { results.append(best) }
        }
        return results
    }

    // MARK: Fixture

    static func makeFixture(workDir: URL) async throws -> URL {
        let dest = workDir.appendingPathComponent("benchmark-fixture.wav")
        let fm = FileManager.default
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        if let source = newestWorkWav(in: workDir) {
            try trim(source: source, to: dest, seconds: fixtureSeconds)
            return dest
        }
        try await synthesise(to: dest)
        return dest
    }

    /// The newest converted recording (`<base>.wav`, 16 kHz mono) in the
    /// work dir, excluding our own fixture.
    static func newestWorkWav(in workDir: URL) -> URL? {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(at: workDir, includingPropertiesForKeys: keys) else { return nil }
        return entries
            .filter { $0.pathExtension.lowercased() == "wav" && $0.lastPathComponent != "benchmark-fixture.wav" }
            .compactMap { url -> (URL, Date)? in
                guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true,
                      let d = v.contentModificationDate else { return nil }
                return (url, d)
            }
            .max { $0.1 < $1.1 }?.0
    }

    /// Copy the first `seconds` of `source` into `dest` in the same format.
    static func trim(source: URL, to dest: URL, seconds: Double) throws {
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        let frames = min(input.length, AVAudioFramePosition(seconds * format.sampleRate))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        else { throw CocoaError(.fileReadUnknown) }
        try input.read(into: buffer, frameCount: AVAudioFrameCount(frames))
        try? FileManager.default.removeItem(at: dest)
        let output = try AVAudioFile(forWriting: dest, settings: input.fileFormat.settings,
                                     commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        try output.write(from: buffer)
    }

    /// On-device text-to-speech fixture (Apple's system voice, nothing bundled).
    static func synthesise(to dest: URL) async throws {
        let text = """
        Good morning everyone, and thank you for joining. Today we are reviewing the quarterly \
        roadmap. The first item is the transcription engine, which shipped last month. The second \
        item is the listing, which needs new screenshots. Edward will send the updated copy by \
        Friday, and Marc will prepare the benchmark on the laptop. We agreed the release should go \
        out in the first week of October. The day rate for the contractor is eight hundred and \
        fifty pounds per day. Are there any questions? No. Then let us close the meeting here.
        """
        try? FileManager.default.removeItem(at: dest)
        let synthesizer = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        var file: AVAudioFile?
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var finished = false
            synthesizer.write(utterance) { buffer in
                guard !finished else { return }
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 {   // end of speech
                    finished = true
                    continuation.resume()
                    return
                }
                do {
                    if file == nil {
                        file = try AVAudioFile(forWriting: dest, settings: pcm.format.settings,
                                               commonFormat: pcm.format.commonFormat,
                                               interleaved: pcm.format.isInterleaved)
                    }
                    try file?.write(from: pcm)
                } catch {
                    finished = true
                    continuation.resume(throwing: error)
                }
            }
        }
        file = nil
        guard FileManager.default.fileExists(atPath: dest.path) else { throw CocoaError(.fileWriteUnknown) }
    }
}

/// Samples this process's resident size on a timer and keeps the maximum.
final class MemorySampler: @unchecked Sendable {
    private var timer: DispatchSourceTimer?
    private let lock = NSLock()
    private var peak: UInt64 = 0

    func start() {
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now(), repeating: .milliseconds(100))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let now = Self.residentBytes()
            self.lock.lock(); self.peak = max(self.peak, now); self.lock.unlock()
        }
        t.resume()
        timer = t
    }

    /// Stop sampling and return the peak in bytes.
    func stop() -> UInt64 {
        timer?.cancel(); timer = nil
        lock.lock(); defer { lock.unlock() }
        return peak
    }

    static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.resident_size : 0
    }
}
