import SwiftUI
import DistavoCore
import DistavoEmbedded
import WhisperKit
import FluidAudio

/// "Download now" with a total, a progress line and Cancel (spec §5.10).
///
/// Progress comes from `controller.modelProgress`, published by
/// `WatcherController` — that controller owns the app's one
/// `ModelCoordinator.setProgressHandler` registration (`wireEmbeddedProgress()`,
/// called once at init), so this view never calls `setProgressHandler` itself;
/// only one handler may exist at runtime.
struct ModelDownloadButton: View {
    @ObservedObject var controller: WatcherController
    let modelIDs: [String]
    let totalMB: Int
    @State private var running = false
    @State private var resultMessage: String?
    /// Set the instant Cancel is tapped — the SDK downloads can't be interrupted
    /// mid-file, so this overrides `controller.modelProgress` until the current
    /// model finishes and `prefetch` actually stops, rather than leaving the
    /// button looking unresponsive.
    @State private var cancelRequested = false

    private var statusText: String? {
        if running {
            return cancelRequested ? "Cancelling after the current model…" : (controller.modelProgress ?? "Starting…")
        }
        return resultMessage
    }

    var body: some View {
        HStack {
            Button(running ? "Downloading…" : "Download now (\(totalMB) MB)") { start() }
                .disabled(running || modelIDs.isEmpty)
            if running {
                Button("Cancel") {
                    cancelRequested = true
                    Task { await ModelCoordinator.shared.cancelDownloads() }
                }
            }
            if let statusText {
                Text(statusText).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func start() {
        running = true
        cancelRequested = false
        resultMessage = nil
        Task {
            do {
                let outcome = try await ModelCoordinator.shared.prefetch(ids: modelIDs, includeDetector: true) { model in
                    try await ModelPrefetcher.download(model)
                }
                await MainActor.run {
                    resultMessage = outcome == .cancelled
                        ? "Cancelled — models downloaded so far are kept" : "Ready"
                    running = false
                }
            } catch {
                await MainActor.run { resultMessage = error.localizedDescription; running = false }
            }
        }
    }
}

/// Implements `ModelCoordinator.prefetch`'s `download` closure using each
/// engine's download-only entry point — no model is loaded into memory here.
enum ModelPrefetcher {
    static func download(_ model: EmbeddedModel?) async throws {
        guard let model else {
            // The language-detector variant, shared by every catalog model.
            _ = try await WhisperKit.download(variant: EmbeddedModelCatalog.languageDetectorName,
                                              downloadBase: EmbeddedModelStore.modelsDirectory,
                                              from: "argmaxinc/whisperkit-coreml")
            return
        }
        switch model.engine {
        case .whisperKit:
            _ = try await WhisperKit.download(variant: model.whisperKitName,
                                              downloadBase: EmbeddedModelStore.modelsDirectory,
                                              from: model.whisperKitRepo ?? "argmaxinc/whisperkit-coreml")
        case .parakeet:
            _ = try await AsrModels.download(to: EmbeddedModelStore.parakeetDirectory)
        }
    }
}
