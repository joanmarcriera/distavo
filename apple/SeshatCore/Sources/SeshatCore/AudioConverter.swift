import Foundation
import AVFoundation

public struct AudioConverterError: Error, LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Native replacement for the ffmpeg call in `meeting_pipeline/transcribe.py`
/// (`-ac 1 -ar 16000 -c:a pcm_s16le`). Uses AVFoundation so the app can be
/// sandboxed and ship on the Mac App Store (no GPL ffmpeg). AVFoundation cannot
/// decode MKV/WebM — those are rejected with a clear, actionable message.
public enum AudioConverter {

    /// Extensions AVFoundation can't decode; ask the user to pre-convert.
    public static let unsupportedExtensions: Set<String> = [".mkv", ".webm"]

    /// Target output format: 16 kHz, mono, 16-bit signed PCM (what WhisperX wants).
    private static var targetFormat: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000,
                      channels: 1, interleaved: true)!
    }

    /// Convert any AVFoundation-readable recording to a 16 kHz mono PCM WAV at `dest`.
    public static func convertToWav(source: URL, dest: URL) async throws {
        let ext = "." + source.pathExtension.lowercased()
        if unsupportedExtensions.contains(ext) {
            throw AudioConverterError(
                "\(source.lastPathComponent): \(ext) files aren't supported by this build "
                + "(AVFoundation can't decode them). Convert to .m4a/.mp4/.wav first.")
        }

        let asset = AVURLAsset(url: source)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = audioTracks.first else {
            throw AudioConverterError("\(source.lastPathComponent): no audio track found.")
        }

        let reader = try AVAssetReader(asset: asset)
        let readerSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: readerSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw AudioConverterError("\(source.lastPathComponent): cannot read audio track.")
        }
        reader.add(output)

        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)

        let format = targetFormat
        let audioFile = try AVAudioFile(
            forWriting: dest, settings: format.settings,
            commonFormat: .pcmFormatInt16, interleaved: true)

        guard reader.startReading() else {
            throw AudioConverterError(
                "\(source.lastPathComponent): could not start reading "
                + "(\(reader.error?.localizedDescription ?? "unknown error")).")
        }

        while let sampleBuffer = output.copyNextSampleBuffer() {
            if let buffer = pcmBuffer(from: sampleBuffer, format: format), buffer.frameLength > 0 {
                try audioFile.write(from: buffer)
            }
        }

        if reader.status == .failed {
            throw AudioConverterError(
                "\(source.lastPathComponent): read failed "
                + "(\(reader.error?.localizedDescription ?? "unknown error")).")
        }

        let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path)
        if (attrs?[.size] as? Int) ?? 0 == 0 {
            throw AudioConverterError("\(source.lastPathComponent): conversion produced no audio.")
        }
    }

    /// Copy a decoded LPCM `CMSampleBuffer` into an `AVAudioPCMBuffer`.
    private static func pcmBuffer(
        from sampleBuffer: CMSampleBuffer, format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        let length = CMBlockBufferGetDataLength(blockBuffer)
        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0 else { return nil }
        let frames = AVAudioFrameCount(length / bytesPerFrame)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let dest = buffer.int16ChannelData else { return nil }
        buffer.frameLength = frames
        let status = CMBlockBufferCopyDataBytes(
            blockBuffer, atOffset: 0, dataLength: length, destination: dest[0])
        return status == kCMBlockBufferNoErr ? buffer : nil
    }
}
