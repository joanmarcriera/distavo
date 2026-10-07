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

    /// Seconds of audio in `url`, or nil when AVFoundation cannot open it as
    /// an audio file (a video container, an unsupported codec, a truncated
    /// header). Callers treat nil as "unknown" — never as "short".
    public static func durationSeconds(of url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let rate = file.fileFormat.sampleRate
        guard rate > 0 else { return nil }
        return Double(file.length) / rate
    }

    /// Convert any AVFoundation-readable recording to a 16 kHz mono PCM WAV at `dest`.

    public static func convertToWav(source: URL, dest: URL) async throws {
        let ext = "." + source.pathExtension.lowercased()
        if unsupportedExtensions.contains(ext) {
            throw AudioConverterError(
                "\(source.lastPathComponent): \(ext) files aren't supported by this build "
                + "(AVFoundation can't decode them). Convert to .m4a/.mp4/.wav first.")
        }

        // File-to-file first: it never opens an audio device (see below). Anything
        // AVAudioFile cannot open, or fails on, goes through the asset reader.
        if (try? convertWithAudioFile(source: source, dest: dest)) == true { return }
        try? FileManager.default.removeItem(at: dest)
        try await convertWithAssetReader(source: source, dest: dest)
    }

    /// Decode with `AVAudioFile` + `AVAudioConverter`: pure file-to-file work.
    ///
    /// Why this exists (1.18): `AVAssetReader` with rate/channel conversion builds an
    /// offline AudioQueue render pipeline, which binds to the default audio DEVICE
    /// (`AudioDeviceCreateIOProcID`). In a clean macOS 26 VM that made macOS ask for
    /// the microphone the first time ANY file was processed, and the conversion
    /// blocked until the prompt was answered. The VM has one virtual device for
    /// input and output, so a physical Mac may not prompt (not confirmed either
    /// way); converting a file has no reason to open a device at all.
    ///
    /// The rate is converted at the source channel count and the channels are then
    /// mixed here, so both sides of an in-app recording (left = microphone,
    /// right = system audio) always reach the transcript.
    ///
    /// - Returns: false when `AVAudioFile` cannot open the source (a video
    ///   container, an unknown codec); the caller then uses the asset reader.
    static func convertWithAudioFile(source: URL, dest: URL) throws -> Bool {
        guard let input = try? AVAudioFile(forReading: source) else { return false }
        let inFormat = input.processingFormat
        let channels = inFormat.channelCount
        guard channels > 0, inFormat.sampleRate > 0, input.length > 0,
              let midFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000,
                                            channels: channels, interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: midFormat) else { return false }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue

        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let outFormat = targetFormat
        let output = try AVAudioFile(forWriting: dest, settings: outFormat.settings,
                                     commonFormat: .pcmFormatInt16, interleaved: true)

        let chunk: AVAudioFrameCount = 16384
        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: chunk),
              let midBuffer = AVAudioPCMBuffer(pcmFormat: midFormat, frameCapacity: chunk),
              let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: chunk) else { return false }

        var readError: Error?
        var finished = false
        while !finished {
            midBuffer.frameLength = 0
            var convertError: NSError?
            let status = converter.convert(to: midBuffer, error: &convertError) { _, inputStatus in
                inBuffer.frameLength = 0
                // Reading at the end of the file throws (eofErr) instead of returning 0 frames.
                if input.framePosition < input.length {
                    do { try input.read(into: inBuffer, frameCount: chunk) } catch { readError = error }
                }
                if readError != nil || inBuffer.frameLength == 0 {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return inBuffer
            }
            if let readError { throw readError }
            if status == .error { throw convertError ?? AudioConverterError("audio conversion failed") }
            if status == .endOfStream || status == .inputRanDry { finished = true }

            let frames = Int(midBuffer.frameLength)
            guard frames > 0, let source = midBuffer.floatChannelData,
                  let target = outBuffer.int16ChannelData else { continue }
            // Same gain as the asset-reader mixdown this replaces (measured: one side
            // of a stereo file comes out 3 dB down, i.e. sum / sqrt(channels)), so
            // levels reaching the transcriber are unchanged. Loud correlated stereo clips, as before.
            let scale = 1 / Float(channels).squareRoot()
            for i in 0..<frames {
                var sum: Float = 0
                for ch in 0..<Int(channels) { sum += source[ch][i] }
                target[0][i] = Int16(max(-1, min(1, sum * scale)) * 32767)
            }
            outBuffer.frameLength = AVAudioFrameCount(frames)
            try output.write(from: outBuffer)
        }
        return output.length > 0
    }

    /// The original path: `AVAssetReader` decodes and converts. Used for sources
    /// `AVAudioFile` cannot open (video containers). It may touch the default
    /// audio device (see `convertWithAudioFile`).
    static func convertWithAssetReader(source: URL, dest: URL) async throws {
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
