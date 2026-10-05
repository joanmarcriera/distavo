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
    /// Download state lives on the model (not view `@State`) so switching Settings
    /// panes — which unmounts this view — never loses an in-flight download or its Cancel.
    @ObservedObject var model: SettingsModel

    private var statusText: String? {
        if model.downloadRunning {
            return model.downloadCancelRequested ? "Cancelling after the current model…" : (controller.modelProgress ?? "Starting…")
        }
        return model.downloadResultMessage
    }

    var body: some View {
        HStack {
            Button(model.downloadRunning ? "Downloading…" : "Download now (\(model.downloadTotalMB) MB)") { model.startDownload() }
                .disabled(model.downloadRunning || model.downloadSet.isEmpty)
            if model.downloadRunning {
                Button("Cancel") {
                    model.downloadCancelRequested = true
                    Task { await ModelCoordinator.shared.cancelDownloads() }
                }
            }
            if let statusText {
                Text(statusText).font(.caption).foregroundStyle(.secondary)
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
