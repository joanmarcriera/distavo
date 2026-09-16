import Accelerate
import AVFoundation
import Foundation

/// Balances the loudness of the meeting recorder's stereo WAV (left = mic,
/// right = system audio) so a quiet speaker isn't drowned by the meeting side
/// — in playback and in the mono downmix the transcriber hears.
///
/// Boost-only: the quieter channel is raised toward the louder channel's
/// *active* loudness (RMS over windows that clear a noise gate, so silence
/// between sentences doesn't skew the measurement). The gain is capped and
/// peak-limited; a silent channel (denied permission) is never amplified.
///
/// **System-audio-silent fallback (Vikunja #2060):** when the system-audio
/// tap fails silently (permission denied/revoked mid-call), the right
/// channel never clears `silenceFloor` and there is nothing left to balance
/// against — the old behaviour just moved the file unchanged, leaving the
/// mic at its raw (often ~10 dB quiet) level next to a dead channel, which
/// dropped whole minutes of speech from a plain transcription. Instead,
/// `balance()` downmixes to mono from the left (mic) channel alone and
/// applies loudness normalisation — a windowed-RMS gain toward
/// `monoNormalizationTarget`, capped and peak-limited exactly like the
/// stereo boost — before the file ever reaches ASR, and logs one Activity
/// line saying so. The same normalisation applies to an already-mono
/// recording that arrives quiet; a genuinely silent file is still never
/// amplified.
public enum StereoBalancer {

    /// Ignore windows quieter than this when measuring loudness (~ -50 dBFS).
    static let noiseGate: Float = 0.003
    /// A channel whose peak never clears this is treated as silent.
    static let silenceFloor: Float = 0.001
    /// Never boost by more than +24 dB.
    static let maxGain: Float = 16.0
    /// Post-gain peak ceiling.
    static let peakCeiling: Float = 0.99
    /// Skip the rewrite when no channel needs more than +0.5 dB.
    static let minWorthwhileGain: Float = 1.06
    /// Target active (noise-gated) RMS for the mono normalisation fallback —
    /// roughly -18 dBFS, a simple windowed-RMS proxy for the ~-16 LUFS
    /// integrated-loudness target EBU R128 recommends for speech. True LUFS
    /// needs K-weighting and gated multi-block integration; this is the
    /// cleanly-implementable-with-Accelerate approximation, applied only to
    /// the mono fallback path (never to the normal stereo balance).
    static let monoNormalizationTarget: Float = 0.125

    private static let chunkFrames: AVAudioFrameCount = 1 << 16

    /// Per-channel peak and noise-gated active RMS for a whole file — the one
    /// measurement pass shared by the stereo silent-channel check, the
    /// stereo balance gains, and the mono normalisation fallback.
    private struct ChannelStats {
        let channelCount: Int
        let peaks: [Float]
        let activeRMS: [Float]  // 0 when a channel never clears `noiseGate`
    }

    /// Balance `source` into `destination`, consuming `source`. When no
    /// adjustment is needed the file is simply moved. `activityLog` records
    /// the mono/loudness-normalisation fallback when it fires (defaults to
    /// the app's real activity log; tests inject a scratch one).
    public static func balance(from source: URL, to destination: URL,
                                activityLog: ActivityLog = ActivityLog()) throws {
        let stats = try analyzeChannels(url: source)

        if stats.channelCount == 2, stats.peaks[1] <= silenceFloor {
            // System audio never registered: nothing to balance against, and
            // a dead right channel plus an unadjusted mic is exactly what
            // drops speech from ASR. Downmix left-only and normalise.
            try downmixAndNormalize(channel: 0, stats: stats, from: source, to: destination)
            activityLog.append(
                "Meeting capture: system audio was silent — downmixed to mono " +
                "(microphone only) and loudness-normalised before transcription.")
            return
        }

        if stats.channelCount == 2 {
            if let gains = stereoGains(from: stats), gains.contains(where: { $0 >= minWorthwhileGain }) {
                try applyGains(gains, from: source, to: destination)
                try FileManager.default.removeItem(at: source)
                return
            }
            try moveUnchanged(from: source, to: destination)
            return
        }

        if stats.channelCount == 1 {
            let gain = normalizationGain(activeRMS: stats.activeRMS[0], peak: stats.peaks[0])
            if gain >= minWorthwhileGain {
                try applyGains([gain], from: source, to: destination)
                try FileManager.default.removeItem(at: source)
                activityLog.append(
                    "Meeting capture: quiet recording loudness-normalised before transcription.")
                return
            }
        }

        try moveUnchanged(from: source, to: destination)
    }

    private static func moveUnchanged(from source: URL, to destination: URL) throws {
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: source, to: destination)
    }

    private static func analyzeChannels(url: URL) throws -> ChannelStats {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32,
                                    interleaved: false)
        let format = file.processingFormat
        let channels = Int(format.channelCount)
        let windowFrames = max(1, Int(format.sampleRate / 10))  // ~100 ms

        var activeSumSq = [Double](repeating: 0, count: channels)
        var activeFrames = [Double](repeating: 0, count: channels)
        var peaks = [Float](repeating: 0, count: channels)

        guard channels > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames)
        else { return ChannelStats(channelCount: channels, peaks: peaks, activeRMS: []) }

        while file.framePosition < file.length {
            try file.read(into: buffer)
            let frames = Int(buffer.frameLength)
            guard frames > 0, let data = buffer.floatChannelData else { break }
            for ch in 0..<channels {
                var chunkPeak: Float = 0
                vDSP_maxmgv(data[ch], 1, &chunkPeak, vDSP_Length(frames))
                peaks[ch] = max(peaks[ch], chunkPeak)
                var offset = 0
                while offset < frames {
                    let count = min(windowFrames, frames - offset)
                    var rms: Float = 0
                    vDSP_rmsqv(data[ch] + offset, 1, &rms, vDSP_Length(count))
                    if rms > noiseGate {
                        activeSumSq[ch] += Double(rms * rms) * Double(count)
                        activeFrames[ch] += Double(count)
                    }
                    offset += count
                }
            }
        }

        let activeRMS = (0..<channels).map { ch -> Float in
            activeFrames[ch] > 0 ? Float((activeSumSq[ch] / activeFrames[ch]).squareRoot()) : 0
        }
        return ChannelStats(channelCount: channels, peaks: peaks, activeRMS: activeRMS)
    }

    /// Per-channel boost gains toward the louder channel's active loudness,
    /// or nil when neither channel has usable signal to reference.
    private static func stereoGains(from stats: ChannelStats) -> [Float]? {
        guard let reference = stats.activeRMS.max(), reference > 0 else { return nil }
        return zip(stats.activeRMS, stats.peaks).map { loudness, peak in
            guard loudness > 0 else { return 1 }  // silent: never amplify
            var gain = min(reference / loudness, maxGain)
            if peak > 0 { gain = min(gain, peakCeiling / peak) }
            return max(gain, 1)  // boost-only
        }
    }

    /// Gain to bring `activeRMS` up to `monoNormalizationTarget`, capped at
    /// `maxGain` and peak-limited to `peakCeiling`. Boost-only, like the
    /// stereo gains: a channel already at or above target is left alone
    /// rather than attenuated. A channel with no active signal (never clears
    /// the noise gate — genuinely silent) stays at unity gain: normalisation
    /// must never amplify silence into audible noise.
    private static func normalizationGain(activeRMS: Float, peak: Float) -> Float {
        guard activeRMS > 0, activeRMS < monoNormalizationTarget else { return 1 }
        var gain = min(monoNormalizationTarget / activeRMS, maxGain)
        if peak > 0 { gain = min(gain, peakCeiling / peak) }
        return max(gain, 1)
    }

    /// Downmix `source`'s channel `channel` (the mic) to mono, applying the
    /// loudness-normalisation gain, and write the result to `destination`.
    /// Used when the paired channel (system audio) is silent — see
    /// `balance()`.
    private static func downmixAndNormalize(channel: Int, stats: ChannelStats,
                                             from source: URL, to destination: URL) throws {
        let gain = normalizationGain(activeRMS: stats.activeRMS[channel], peak: stats.peaks[channel])
        let input = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32,
                                     interleaved: false)
        guard let monoFormat = AVAudioFormat(
            standardFormatWithSampleRate: input.processingFormat.sampleRate, channels: 1)
        else { throw CocoaError(.fileWriteUnknown) }
        var monoSettings = input.fileFormat.settings
        monoSettings[AVNumberOfChannelsKey] = 1

        try? FileManager.default.removeItem(at: destination)
        // Scope the writer so it flushes/closes before callers read the file.
        do {
            let output = try AVAudioFile(forWriting: destination, settings: monoSettings,
                                          commonFormat: .pcmFormatFloat32, interleaved: false)
            guard let inBuffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat,
                                                   frameCapacity: chunkFrames),
                  let outBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: chunkFrames)
            else { throw CocoaError(.fileWriteUnknown) }
            while input.framePosition < input.length {
                try input.read(into: inBuffer)
                let frames = Int(inBuffer.frameLength)
                guard frames > 0, let inData = inBuffer.floatChannelData,
                      let outData = outBuffer.floatChannelData
                else { break }
                var g = gain
                vDSP_vsmul(inData[channel], 1, &g, outData[0], 1, vDSP_Length(frames))
                outBuffer.frameLength = AVAudioFrameCount(frames)
                try output.write(from: outBuffer)
            }
        }
        try FileManager.default.removeItem(at: source)
    }

    private static func applyGains(_ gains: [Float], from source: URL,
                                   to destination: URL) throws {
        let input = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32,
                                    interleaved: false)
        let format = input.processingFormat
        try? FileManager.default.removeItem(at: destination)
        // Scope the writer so it flushes/closes before callers read the file.
        do {
            let output = try AVAudioFile(forWriting: destination,
                                         settings: input.fileFormat.settings,
                                         commonFormat: .pcmFormatFloat32, interleaved: false)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames)
            else { throw CocoaError(.fileWriteUnknown) }
            while input.framePosition < input.length {
                try input.read(into: buffer)
                let frames = Int(buffer.frameLength)
                guard frames > 0, let data = buffer.floatChannelData else { break }
                for ch in 0..<min(gains.count, Int(format.channelCount)) where gains[ch] != 1 {
                    var gain = gains[ch]
                    vDSP_vsmul(data[ch], 1, &gain, data[ch], 1, vDSP_Length(frames))
                }
                try output.write(from: buffer)
            }
        }
    }
}
