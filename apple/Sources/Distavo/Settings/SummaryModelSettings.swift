import SwiftUI
import DistavoCore
import DistavoEmbedded

/// Which editions offer the downloadable local summary model (Vikunja #2198, S6).
/// Rollout decision: Direct only for now; the App Store and Setapp builds keep
/// Apple Intelligence only (sandbox/review verification of the MLX engine is
/// still pending). The engine code stays linked in every edition — only the
/// UI and the routing are gated, so flipping this is a one-line change.
enum SummaryModelEdition {
    static var offersDownloadedModels: Bool {
        #if EDITION_DIRECT
        true
        #else
        false
        #endif
    }

    /// Catalogue entries this edition AND this Mac may use. Always contains
    /// Apple's model; downloadable ones only where the edition offers them.
    static func selectable(memoryBytes: UInt64 = HardwareProbe.physicalMemoryBytes) -> [EmbeddedSummaryModel] {
        EmbeddedSummaryModelCatalog.selectable(memoryBytes: memoryBytes).filter {
            $0.downloadMB == 0 || offersDownloadedModels
        }
    }
}

/// "Summary model" picker plus, for a downloadable model, the disclosure,
/// "Download now", live status, disk warning and "Remove". Shown inside the
/// Summarisation section only when on-device summaries are switched on and
/// the Mac (and edition) offer more than Apple's built-in model.
struct SummaryModelSettings: View {
    @Binding var modelID: String
    @State private var status: SummaryModelStatus = .notDownloaded
    @State private var freeMB = 0

    private var choices: [EmbeddedSummaryModel] { SummaryModelEdition.selectable() }
    private var selected: EmbeddedSummaryModel { EmbeddedSummaryModelCatalog.model(id: modelID) }

    static func label(_ m: EmbeddedSummaryModel) -> String {
        m.downloadMB == 0 ? "Apple Intelligence"
            : "\(m.displayName.replacingOccurrences(of: " (local)", with: "")) (local, ~\(Int((Double(m.downloadMB) / 1000).rounded())) GB)"
    }

    var body: some View {
        if choices.count > 1 {
            HStack {
                Picker("Summary model", selection: $modelID) {
                    ForEach(choices) { m in Text(Self.label(m)).tag(m.id) }
                }
                HelpButton(text: "‘Apple Intelligence’ is built in and English-only with a small context window. ‘Gemma 4’ is a larger open model that runs on this Mac’s GPU: it follows your prompt style and note language (including Catalan and Spanish) and handles long meetings in one pass. It must be downloaded once, and needs at least 16 GB of memory.")
            }
            if selected.downloadMB > 0 { downloadControls(selected) }
        }
    }

    @ViewBuilder
    private func downloadControls(_ model: EmbeddedSummaryModel) -> some View {
        // Disclosure BEFORE any download, whatever the current state.
        Text("Downloads ~\(Int((Double(model.downloadMB) / 1000).rounded())) GB from huggingface.co once; recordings never leave this Mac.")
            .font(.caption).foregroundStyle(.secondary)
        if freeMB < model.downloadMB * SummaryModelReadiness.diskFactor, !isReady {
            Text("⚠︎ Only \(freeMB / 1000) GB free; about \(model.downloadMB * SummaryModelReadiness.diskFactor / 1000) GB is needed to download and verify.")
                .font(.caption).foregroundStyle(.orange)
        }
        HStack {
            switch status {
            case .downloading(let f):
                ProgressView(value: f).frame(maxWidth: 160)
            default: EmptyView()
            }
            if isReady || isRemovable {
                Button("Remove") { Task { await SummaryModelManager.shared.remove(model); await refresh(model) } }
            }
            if !isReady, !isDownloading {
                Button(retryLabel) { Task { await SummaryModelManager.shared.startDownload(model); await refresh(model) } }
            }
            Text(statusText(model)).font(.caption).foregroundStyle(statusIsError ? .orange : .secondary)
        }
        .task(id: model.id) {
            // Poll while visible: the download runs in the background.
            while !Task.isCancelled {
                await refresh(model)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private var isReady: Bool { if case .ready = status { return true } else { return false } }
    private var isDownloading: Bool { if case .downloading = status { return true } else { return false } }
    private var isRemovable: Bool { if case .failed = status { return true } else { return false } }
    private var statusIsError: Bool { if case .failed = status { return true } else { return false } }
    private var retryLabel: String { if case .failed = status { return "Download again" } else { return "Download now" } }

    private func statusText(_ model: EmbeddedSummaryModel) -> String {
        switch status {
        case .notDownloaded: return "Not downloaded"
        case .downloading(let f): return "Downloading \(Int(f * 100))%"
        case .ready: return "Ready"
        case .removed: return "Removed"
        case .failed(let why): return "Failed: \(why)"
        }
    }

    private func refresh(_ model: EmbeddedSummaryModel) async {
        let s = await SummaryModelManager.shared.status(model)
        let free = Int(EmbeddedModelStore.freeSpaceBytes() / (1024 * 1024))
        await MainActor.run { status = s; freeMB = free }
    }
}
