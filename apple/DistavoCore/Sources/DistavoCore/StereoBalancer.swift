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

    private static let chunkFrames: AVAudioFrameCount = 1 << 16

    /// Balance `source` into `destination`, consuming `source`. When no
    /// adjustment is needed the file is simply moved. Non-stereo files are
    /// moved unchanged.
    public static func balance(from source: URL, to destination: URL) throws {
        let gains = try measureGains(url: source)
        guard let gains, gains.contains(where: { $0 >= minWorthwhileGain }) else {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: source, to: destination)
            return
        }
        try applyGains(gains, from: source, to: destination)
        try FileManager.default.removeItem(at: source)
    }

    /// Per-channel boost gains, or nil when the file isn't a 2-channel file
    /// or has no usable signal to reference.
    private static func measureGains(url: URL) throws -> [Float]? {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32,
                                   interleaved: false)
        let format = file.processingFormat
        guard format.channelCount == 2 else { return nil }
        let channels = 2
        let windowFrames = max(1, Int(format.sampleRate / 10))  // ~100 ms

        var activeSumSq = [Double](repeating: 0, count: channels)
        var activeFrames = [Double](repeating: 0, count: channels)
        var peaks = [Float](repeating: 0, count: channels)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames)
        else { throw CocoaError(.fileReadUnknown) }
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

        let loudness = (0..<channels).map { ch -> Float in
            let heard = peaks[ch] > silenceFloor && activeFrames[ch] > 0
            return heard ? Float((activeSumSq[ch] / activeFrames[ch]).squareRoot()) : 0
        }
        guard let reference = loudness.max(), reference > 0 else { return nil }

        return (0..<channels).map { ch in
            guard loudness[ch] > 0 else { return 1 }  // silent: never amplify
            var gain = min(reference / loudness[ch], maxGain)
            if peaks[ch] > 0 { gain = min(gain, peakCeiling / peaks[ch]) }
            return max(gain, 1)  // boost-only
        }
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
