import Foundation
import AVFoundation

/// Cuts short audio clips out of a recording (Vikunja #2950, "Export Key Moment
/// Clips…"). Uses `AVAssetExportSession` with the Apple M4A preset, like
/// `AudioConverter` uses AVFoundation rather than ffmpeg, so it is App Store safe.
///
/// Works on whatever the app accepts as a recording: the recorder's 48 kHz stereo
/// WAV (L = mic, R = system audio, kept as is - the clip sounds like the take), a
/// WAV compacted to 16 kHz mono, m4a/mp3/etc. and video containers (audio only).
/// Never overwrites: `uniqueDestination` picks `<base> clip 03m12s.m4a`, then
/// `... 2.m4a`. Pure file work; the folder to write into is chosen by the app layer.
public enum ClipExporter {

    public struct Failure: Error, LocalizedError, Equatable {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    /// Outcome of one marker's export.
    public struct Result: Equatable, Sendable {
        public var offsetSeconds: Double
        public var url: URL?
        public var error: String?
    }

    /// "03m12s" (or "1h03m12s") for a marker offset - what the file name carries.
    public static func timeLabel(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return s >= 3600
            ? String(format: "%dh%02dm%02ds", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%02dm%02ds", s / 60, s % 60)
    }

    /// `<folder>/<base> clip 03m12s.m4a`, or `... 2.m4a`, `... 3.m4a` when taken.
    public static func uniqueDestination(folder: URL, base: String, markerSeconds: Double,
                                         fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let stem = "\(base) clip \(timeLabel(markerSeconds))"
        var candidate = folder.appendingPathComponent("\(stem).m4a")
        var n = 2
        while fileExists(candidate) {
            candidate = folder.appendingPathComponent("\(stem) \(n).m4a")
            n += 1
        }
        return candidate
    }

    /// Duration of the audio in `source`, or nil when unreadable.
    public static func duration(of source: URL) async -> Double? {
        guard let d = try? await AVURLAsset(url: source).load(.duration) else { return nil }
        let s = CMTimeGetSeconds(d)
        return s.isFinite && s > 0 ? s : nil
    }

    /// Export `range` of `source` to `destination` (an `.m4a` that must not exist).
    public static func export(source: URL, range: RecordingBookmarks.ClipRange, to destination: URL) async throws {
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw Failure("The recording \(source.lastPathComponent) is no longer at \(source.deletingLastPathComponent().path) - it was moved or deleted.")
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw Failure("\(destination.lastPathComponent) already exists; not overwriting it.")
        }
        let asset = AVURLAsset(url: source)
        guard let audio = try? await asset.loadTracks(withMediaType: .audio), !audio.isEmpty else {
            throw Failure("\(source.lastPathComponent) has no audio Distavo can read.")
        }
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw Failure("This Mac cannot export m4a clips from \(source.lastPathComponent).")
        }
        session.timeRange = CMTimeRange(
            start: CMTime(seconds: range.start, preferredTimescale: 600),
            end: CMTime(seconds: range.end, preferredTimescale: 600))
        do {
            if #available(macOS 15.0, *) {
                try await session.export(to: destination, as: .m4a)
            } else {
                session.outputURL = destination
                session.outputFileType = .m4a
                await session.export()
                if session.status != .completed { throw session.error ?? Failure("export did not complete") }
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)   // never leave a half-written clip
            throw Failure("Could not export \(destination.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// One clip per marker into `folder`, sequentially. A failing marker is
    /// reported in its `Result` and does not stop the rest; a missing source fails
    /// them all with the same clear message.
    public static func exportClips(source: URL, marks: [RecordingBookmarks.Mark], base: String, folder: URL,
                                   before: Double, after: Double) async -> [Result] {
        let total = await duration(of: source)
        var results: [Result] = []
        for mark in marks {
            guard let range = RecordingBookmarks.clipRange(for: mark.offsetSeconds, before: before, after: after, duration: total) else {
                results.append(Result(offsetSeconds: mark.offsetSeconds, url: nil,
                                      error: FileManager.default.fileExists(atPath: source.path)
                                        ? "The recording has no readable audio." : "The recording \(source.lastPathComponent) is no longer there."))
                continue
            }
            let dest = uniqueDestination(folder: folder, base: base, markerSeconds: mark.offsetSeconds)
            do {
                try await export(source: source, range: range, to: dest)
                results.append(Result(offsetSeconds: mark.offsetSeconds, url: dest, error: nil))
            } catch {
                results.append(Result(offsetSeconds: mark.offsetSeconds, url: nil, error: error.localizedDescription))
            }
        }
        return results
    }

    // MARK: Finding the audio

    /// The recording file behind `base`: the sidecar's relative `source` when it
    /// still exists, else the file in `recordingsDir` (recursively) whose
    /// `DistavoState.baseFor` equals `base` and whose extension is supported.
    /// nil when it was moved or deleted.
    public static func locateSource(base: String, source: String?, recordingsDir: URL) -> URL? {
        let fm = FileManager.default
        if let source, !source.isEmpty, !source.hasPrefix("/"), !source.contains("..") {
            let url = recordingsDir.appendingPathComponent(source)
            if fm.fileExists(atPath: url.path) { return url }
        }
        guard let walker = fm.enumerator(at: recordingsDir, includingPropertiesForKeys: nil,
                                         options: [.skipsHiddenFiles]) else { return nil }
        for case let url as URL in walker {
            guard supportedExtensions.contains("." + url.pathExtension.lowercased()) else { continue }
            if DistavoState.baseFor(recordingsDir: recordingsDir, path: url) == base { return url }
        }
        return nil
    }
}
