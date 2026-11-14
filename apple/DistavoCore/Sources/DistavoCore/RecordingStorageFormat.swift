import Foundation

/// How the built-in recorder stores its stereo WAV on disk (Vikunja #6670).
///
/// The recorder wrote Float32 stereo at the tap's rate (48 kHz): 48 000 x 2 x 4 = 384 000 B/s = 1.38 GB per
/// hour. Findings, in the order of safety:
///
/// * **`full`** (default, also for fresh installs): Float32. Byte-identical to before.
/// * **`int16`**: 16-bit signed PCM at the same rate and channel count: half the size (0.69 GB/h). Every
///   later stage reads the file as Float32 through `AVAudioFile(forReading:commonFormat:)`
///   (`StereoBalancer`, `TrailingSilence`, `AudioConverter`) and writes back with the file's own settings,
///   so a 16-bit file stays 16-bit end to end. The cost is 16-bit quantisation (about -96 dBFS), inaudible
///   for speech and far below the ASR noise floor. Opt-in, because the original take is the user's only copy
///   until compaction.
/// * Not offered: 16 kHz. `AVAudioFile` does not resample between its processing format and its file format,
///   so it needs an `AVAudioConverter` inside the real-time IO callback (risk of dropouts, not testable
///   headless). 16 kHz stereo Int16 would be 0.23 GB/h; `compact_recordings_after_note` already reduces the
///   file to 16 kHz mono once the note exists (the pipeline only ever transcribes 16 kHz). Mono-only for the
///   mic track is not safe: channel L = mic / R = system is what `ChannelSpeakerLabeller` uses to tell the
///   speakers apart.
public enum RecordingStorageFormat: String, Codable, CaseIterable, Equatable, Sendable {
    case full
    case int16

    /// `AVAudioFile(forWriting:settings:)` settings for a stereo recording at `sampleRate`
    /// (keys are the AVFoundation constants' string values, so this file needs no AVFoundation import).
    public func fileSettings(sampleRate: Double, channels: Int = 2) -> [String: Any] {
        [
            "AVFormatIDKey": Int(0x6C70636D),            // kAudioFormatLinearPCM, 'lpcm'
            "AVSampleRateKey": sampleRate,
            "AVNumberOfChannelsKey": channels,
            "AVLinearPCMBitDepthKey": bitDepth,
            "AVLinearPCMIsFloatKey": self == .full,
            "AVLinearPCMIsBigEndianKey": false,
        ]
    }

    public var bitDepth: Int { self == .full ? 32 : 16 }

    /// Bytes written per hour of audio (header ignored).
    public func bytesPerHour(sampleRate: Double, channels: Int = 2) -> Int {
        Int(sampleRate) * channels * (bitDepth / 8) * 3600
    }

    /// Label for Settings.
    public var displayName: String {
        switch self {
        case .full: return "Full quality (32-bit, about 1.4 GB per hour)"
        case .int16: return "Compact (16-bit, about 0.7 GB per hour)"
        }
    }
}
