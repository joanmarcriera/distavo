import Foundation

// Readiness of a downloaded on-device summary model (Vikunja #2198, slice S5).
//
// A pure function of what the app layer observed, so every row of the
// defer-versus-fail table is unit-tested. `.temporarilyUnavailable` defers the
// recording (it is retried, never marked failed); `.unsupported` fails once
// with guidance. Readiness is decided BEFORE transcription, so a deferral costs
// nothing.

/// What the app layer found out about the model's files and download.
public enum SummaryModelDownloadState: Equatable, Sendable {
    /// Nothing usable on disk and no download running.
    case notStarted
    /// A download is running.
    case inProgress(fraction: Double)
    /// Files present and verified against the manifest.
    case verified
    /// The last download failed manifest verification once; it was discarded
    /// and will be fetched again.
    case manifestMismatch
    /// Verification failed twice in a row (or another unrecoverable download
    /// problem): treated as corrupt at the source, not transient.
    case failedPermanently(String)
}

public enum SummaryModelReadiness {
    /// Disk needed before a download starts, as a multiple of the download
    /// size — the same staging-plus-final rule as `ModelCoordinator.ensureFreeSpace`.
    public static let diskFactor = 2

    public static func evaluate(
        model: EmbeddedSummaryModel,
        downloadState: SummaryModelDownloadState,
        memoryGB: Int,
        isAppleSilicon: Bool,
        freeDiskMB: Int
    ) -> EmbeddedReadiness {
        // Things that can never resolve on this Mac come first: no download or
        // retry would help, so say so once.
        if model.engine == .mlx && !isAppleSilicon {
            return .unsupported("\(model.displayName) needs a Mac with Apple silicon — use Apple Intelligence or Ollama in Settings.")
        }
        if memoryGB < model.minimumMemoryGB {
            return .unsupported("\(model.displayName) needs at least \(model.minimumMemoryGB) GB of memory (this Mac has \(memoryGB) GB) — choose a smaller model or use Ollama in Settings.")
        }
        // The system model has nothing to download.
        if model.downloadMB == 0 { return .ready }

        switch downloadState {
        case .verified:
            return .ready
        case .inProgress(let fraction):
            let percent = Int((min(max(fraction, 0), 1)) * 100)
            return .temporarilyUnavailable("\(model.displayName) is downloading (\(percent)%) — notes will be written when it finishes.")
        case .failedPermanently(let why):
            return .unsupported("\(model.displayName) could not be downloaded intact (\(why)) — use Apple Intelligence or Ollama in Settings.")
        case .notStarted, .manifestMismatch:
            let needMB = model.downloadMB * diskFactor
            if freeDiskMB < needMB {
                return .temporarilyUnavailable("\(model.displayName) needs about \(needMB / 1000) GB of free disk space to download — free some space and Distavo will retry.")
            }
            let why = downloadState == .manifestMismatch
                ? "\(model.displayName) failed its integrity check and is being downloaded again."
                : "\(model.displayName) has not been downloaded yet — starting the download now."
            return .temporarilyUnavailable(why)
        }
    }
}
