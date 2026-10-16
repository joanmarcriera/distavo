import AVFoundation
import Accelerate
import Foundation

/// Cuts a long silent tail off a finished recording (Vikunja #2677).
///
/// After an auto-stop on silence (#2665) the file ends with up to M minutes of nothing, and Whisper
/// is known to invent text over long silence. This runs at finalise time, right after
/// `StereoBalancer`, with the SAME gate as `SilenceMonitor` (`StereoBalancer.noiseGate`: a second is
/// silent when every channel's RMS is below it).
///
/// Conservative on purpose: nothing is cut unless at least `minTrimSeconds` of silence ends the
/// file, `tailSeconds` of silence are always kept after the last sound, a file with no sound at all is
/// never touched (it is not ours to decide it is empty), and the file is replaced only after the
/// shorter copy has been written completely.
public enum TrailingSilence {

    /// Do not bother (or risk a rewrite) for less silence than this.
    public static let minTrimSeconds = 30.0
    /// Silence kept after the last sound, so the last word is never clipped.
    public static let tailSeconds = 2.0

    /// Frames to keep, or nil when the file should be left alone. Pure, for tests.
    /// `windowRMS` is the per-window maximum channel RMS; `windowSeconds` its length.
    static func framesToKeep(windowRMS: [Float], windowSeconds: Double, totalFrames: Int64, sampleRate: Double,
                             gate: Float = StereoBalancer.noiseGate) -> Int64? {
        guard let lastLoud = windowRMS.lastIndex(where: { $0 > gate }) else { return nil }
        let soundEnd = Double(lastLoud + 1) * windowSeconds
        let keepSeconds = soundEnd + tailSeconds
        let total = Double(totalFrames) / sampleRate
        guard total - keepSeconds >= minTrimSeconds else { return nil }
        return min(totalFrames, Int64((keepSeconds * sampleRate).rounded(.up)))
    }

    /// Trim `url` in place. Returns the seconds removed (0 = untouched).
    @discardableResult
    public static func trim(_ url: URL, activityLog: ActivityLog = ActivityLog()) throws -> Double {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        let channels = Int(format.channelCount)
        guard channels > 0, file.length > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1 << 16) else { return 0 }
        let windowFrames = max(1, Int(format.sampleRate))        // one second, like SilenceMonitor
        var windows: [Float] = []
        var pending = 0, pendingMax: Float = 0
        file.framePosition = 0
        while file.framePosition < file.length {
            try file.read(into: buffer)
            let frames = Int(buffer.frameLength)
            guard frames > 0, let data = buffer.floatChannelData else { break }
            var offset = 0
            while offset < frames {
                let count = min(windowFrames - pending, frames - offset)
                for ch in 0..<channels {
                    var rms: Float = 0
                    vDSP_rmsqv(data[ch] + offset, 1, &rms, vDSP_Length(count))
                    pendingMax = max(pendingMax, rms)   // a window split across chunks keeps its loudest part
                }
                pending += count; offset += count
                if pending >= windowFrames { windows.append(pendingMax); pending = 0; pendingMax = 0 }
            }
        }
        if pending > 0 { windows.append(pendingMax) }

        guard let keep = framesToKeep(windowRMS: windows, windowSeconds: 1, totalFrames: file.length,
                                      sampleRate: format.sampleRate) else { return 0 }
        let temp = url.deletingLastPathComponent().appendingPathComponent(".trim-\(UUID().uuidString)-\(url.lastPathComponent)")
        do {
            let reader = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
            let writer = try AVAudioFile(forWriting: temp, settings: reader.fileFormat.settings,
                                         commonFormat: .pcmFormatFloat32, interleaved: false)
            var remaining = keep
            while remaining > 0 {
                let want = AVAudioFrameCount(min(Int64(buffer.frameCapacity), remaining))
                try reader.read(into: buffer, frameCount: want)
                guard buffer.frameLength > 0 else { break }
                try writer.write(from: buffer)
                remaining -= Int64(buffer.frameLength)
            }
            // `writer` closes when it goes out of scope; only then is the original replaced.
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        let removed = Double(file.length - keep) / format.sampleRate
        activityLog.append("Meeting capture: trimmed \(Int(removed.rounded())) s of trailing silence before transcription.")
        return removed
    }
}
