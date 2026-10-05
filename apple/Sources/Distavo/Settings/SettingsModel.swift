import SwiftUI
import Combine
import DistavoCore
import DistavoEmbedded

/// The shared model behind every Settings pane (Vikunja #2957).
///
/// Holds the draft `Config` the panes edit plus the derived, edition- and
/// backend-dependent facts (is the built-in engine in use? which models can this
/// Mac run? is there anything to download?). Those used to be inline conditionals
/// in one 650-line view body; as computed properties here, a pane just asks
/// `model.usesBuiltInTranscription` instead of re-deriving it.
///
/// Saving is explicit: edits live in `draft` until `save()` (the bar's Save
/// button) applies them to the controller; `revert()` discards them. Closing the
/// window with pending edits still saves them (see `saveIfNeededOnClose`) —
/// that long-standing behaviour is kept, but the bar now says so.
@MainActor
final class SettingsModel: ObservableObject {
    let controller: WatcherController

    // MARK: Edited state
    @Published var draft: Config
    @Published var openAtLogin: Bool

    // MARK: Transient UI state shared between panes
    @Published var diag = ConnectionDiagnosis()
    @Published var lanWarningHosts: [String] = []
    @Published var showingPermissions = false
    @Published var saved = false
    @Published var modelsOnDisk: String? = EmbeddedModelStore.hasDownloadedModels()
        ? EmbeddedModelStore.diskUsageLabel() : nil
    /// "Download now" state — hoisted here so it survives pane switches (see ModelDownloadButton).
    @Published var downloadRunning = false
    @Published var downloadCancelRequested = false
    @Published var downloadResultMessage: String?
    #if EDITION_DIRECT
    @Published var autoUpdates = true
    #endif

    /// Result of the last "Test connection" run.
    struct ConnectionDiagnosis {
        var whisperx: NetworkScope.EndpointDiagnosis?
        var server: NetworkScope.EndpointDiagnosis?
        var local: NetworkScope.EndpointDiagnosis?
    }

    static let whisperXModels = ["tiny", "base", "small", "medium", "large-v2", "large-v3"]
    let embeddedSupported = HardwareProbe.supportsEmbeddedTranscription

    private var forwarding: AnyCancellable?

    init(controller: WatcherController) {
        self.controller = controller
        draft = controller.config
        openAtLogin = controller.openAtLogin
        // Panes read live controller state (last detected language, benchmark
        // results); re-render them when it changes, as the old view's body did.
        forwarding = controller.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    // MARK: Edition / backend facts

    /// Panes this edition shows (Updates only where Sparkle is compiled in).
    var visiblePanes: [SettingsPane] {
        #if EDITION_DIRECT
        SettingsPane.visible(hasUpdates: true)
        #else
        SettingsPane.visible(hasUpdates: false)
        #endif
    }

    /// The built-in (WhisperKit/Parakeet) engine is both chosen and runnable here.
    var usesBuiltInTranscription: Bool {
        draft.transcribe.backend == "embedded" && embeddedSupported
    }

    /// Opt-in on-device summaries toggle is offered (macOS 26+ with Apple
    /// Intelligence ready) — or already on, so it can always be switched off.
    var offersOnDeviceSummaryToggle: Bool {
        if #available(macOS 26, *) {
            return EmbeddedSummariser.unavailableReason() == nil || draft.summarise.embeddedEnabled
        }
        return false
    }

    /// Title for the Summaries pane's server section depending on the backend mix.
    var summariesSectionTitle: String {
        draft.summarise.embeddedEnabled ? "Summarisation" : "Summarisation (Ollama)"
    }

    /// Which one-line explanation sits under the Summaries backend picker.
    enum SummaryBackendNote {
        case none
        case gemma
        case appleReady
        case appleUnavailable(String)
    }

    var summaryBackendNote: SummaryBackendNote {
        guard draft.summarise.embeddedEnabled, draft.summarise.backend == "embedded" else { return .none }
        if draft.summarise.embeddedModel != EmbeddedSummaryModelCatalog.appleID { return .gemma }
        if let reason = EmbeddedSummariser.unavailableReason() {
            return .appleUnavailable(reason.localizedDescription)
        }
        return .appleReady
    }

    // MARK: Transcription language choices

    /// The catalog, plus a synthetic entry if the saved code isn't recognised
    /// (e.g. a past typo like "esp"), so the existing value stays selected and
    /// visible rather than silently changing — the user can then pick a real one.
    /// `"auto"` (Distavo's own detect-per-meeting choice) is recognised too, so
    /// it doesn't get flagged as a stray code.
    var languageChoices: [WhisperLanguage] {
        let code = draft.transcribe.language
        if code.isEmpty || code == EmbeddedModelCatalog.automaticID
            || WhisperLanguageCatalog.language(forCode: code) != nil {
            return WhisperLanguageCatalog.all
        }
        return [WhisperLanguage(code: code, englishName: "\(code) — not a standard code")]
            + WhisperLanguageCatalog.all
    }

    // MARK: When-done checkboxes (Vikunja #2205)

    func whenDoneBinding(_ action: WhenDoneAction) -> Binding<Bool> {
        Binding(
            get: { self.draft.whenDone.contains(action) },
            set: { isOn in
                if isOn {
                    if !self.draft.whenDone.contains(action) { self.draft.whenDone.append(action) }
                } else {
                    self.draft.whenDone.removeAll { $0 == action }
                }
            })
    }

    /// Same requirement `WatcherController.queueRetryTranscribeBigger` enforces
    /// at run time: a fixed (non-Automatic) built-in model with a bigger
    /// option for its configured language.
    var canRetryTranscribeBigger: Bool {
        embeddedSupported && draft.transcribe.backend == "embedded"
            && !EmbeddedModelCatalog.isAutomatic(draft.transcribe.embeddedModel)
            && EmbeddedModelCatalog.nextBigger(for: draft.transcribe.embeddedModel,
                                               language: draft.transcribe.language,
                                               memoryBytes: HardwareProbe.physicalMemoryBytes,
                                               measuredOK: Benchmark.measuredOK(controller.config.benchmark),
                                               enabledLanguagePacks: draft.transcribe.languagePacks) != nil
    }

    var canRetrySummariseBigger: Bool {
        !(draft.summarise.biggerModel ?? "").isEmpty
    }

    // MARK: Built-in model choices

    /// Models this Mac's memory can actually run (spec §6 gate), plus any the
    /// benchmark has shown to run here (Vikunja #2160).
    var selectableIDs: Set<String> {
        Set(EmbeddedModelCatalog.selectable(measuredOK: Benchmark.measuredOK(controller.config.benchmark)).map(\.id))
    }

    /// Whether this Mac can run the BSC Catalan family — both `bsc-los` and
    /// `bsc-ca-3370h` share the same 16 GB floor, so one check governs both the
    /// "Preferred Catalan model" picker's visibility and what "Download now" fetches.
    var bscSelectable: Bool { selectableIDs.contains("bsc-los") }

    /// The Model picker's rows: selectable catalog entries, plus a synthetic one
    /// when the stored id is neither Automatic nor selectable — a low-memory Mac
    /// may have an explicit `bsc-los` chosen before the memory floor existed, or
    /// the id may be hand-edited/stale. Mirrors `languageChoices`: the existing
    /// value stays selected and visible instead of the Picker landing on nothing.
    var modelChoices: [EmbeddedModel] {
        let stored = draft.transcribe.embeddedModel
        let ids = selectableIDs
        // Pack-only models stay out of the picker until their pack is switched on
        // (Vikunja #2124) — otherwise every language adds a 3 GB row nobody asked for.
        let enabledPackModels = Set(draft.transcribe.enabledLanguagePacks.flatMap(\.modelIDs))
        let selectable = EmbeddedModelCatalog.models.filter {
            ids.contains($0.id)
                && (!EmbeddedModelCatalog.packModelIDs.contains($0.id) || enabledPackModels.contains($0.id) || $0.id == stored)
        }
        guard !EmbeddedModelCatalog.isAutomatic(stored), !ids.contains(stored) else {
            return selectable
        }
        if let known = EmbeddedModelCatalog.models.first(where: { $0.id == stored }) {
            let synthetic = EmbeddedModel(
                id: known.id, displayName: "\(known.displayName) — not available on this Mac",
                engine: known.engine, whisperKitRepo: known.whisperKitRepo, whisperKitName: known.whisperKitName,
                languages: known.languages, downloadMB: known.downloadMB, ramGB: known.ramGB,
                minimumMemoryGB: known.minimumMemoryGB, detail: known.detail)
            return [synthetic] + selectable
        }
        let unknown = EmbeddedModel(
            id: stored, displayName: "\(stored) — not a known model", engine: .whisperKit,
            whisperKitRepo: nil, whisperKitName: "", languages: .whisper,
            downloadMB: 0, ramGB: 0, minimumMemoryGB: 0, detail: "")
        return [unknown] + selectable
    }

    /// Catalog models this Mac cannot run (named in a caption, not shown as dead rows).
    var unselectableModels: [EmbeddedModel] {
        let ids = selectableIDs
        return EmbeddedModelCatalog.models.filter { !ids.contains($0.id) }
    }

    /// What "Download now" fetches for the current choice (spec §5.10).
    var downloadSet: [String] {
        if EmbeddedModelCatalog.isAutomatic(draft.transcribe.embeddedModel) {
            let selectable = selectableIDs
            var ids = ["parakeet-tdt-v3"]
            if bscSelectable { ids.append(draft.transcribe.effectivePreferredCatalanModel) }
            // Enabled language packs this Mac can run (Vikunja #2124).
            for pack in draft.transcribe.enabledLanguagePacks {
                ids += pack.modelIDs.filter { selectable.contains($0) && !ids.contains($0) }
            }
            return ids
        }
        return [draft.transcribe.embeddedModel]
    }

    /// M7: only what "Download now" would actually fetch — a model already on
    /// disk (or the detector, already downloaded) must not inflate the total
    /// the button shows before starting.
    var downloadTotalMB: Int {
        let modelsMB = downloadSet
            .map { EmbeddedModelCatalog.model(id: $0) }
            .filter { !EmbeddedModelStore.isDownloaded($0) }
            .map(\.downloadMB)
            .reduce(0, +)
        let needsDetector = EmbeddedModelCatalog.isAutomatic(draft.transcribe.embeddedModel)
            && !EmbeddedModelStore.isDetectorDownloaded()
        return modelsMB + (needsDetector ? 77 : 0)
    }

    /// Membership of a language pack in `transcribe.language_packs`, kept in catalog order.
    func packBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { self.draft.transcribe.languagePacks.contains(id) },
            set: { on in
                var ids = Set(self.draft.transcribe.languagePacks)
                if on { ids.insert(id) } else { ids.remove(id) }
                self.draft.transcribe.languagePacks = EmbeddedModelCatalog.languagePacks.map(\.id).filter { ids.contains($0) }
            })
    }

    /// Start the model prefetch for the current choice; a second start while one runs is a no-op.
    func startDownload() {
        guard !downloadRunning else { return }
        let ids = downloadSet
        downloadRunning = true
        downloadCancelRequested = false
        downloadResultMessage = nil
        Task {
            do {
                let outcome = try await ModelCoordinator.shared.prefetch(ids: ids, includeDetector: true) { model in
                    try await ModelPrefetcher.download(model)
                }
                downloadResultMessage = outcome == .cancelled
                    ? "Cancelled — models downloaded so far are kept" : "Ready"
            } catch {
                downloadResultMessage = error.localizedDescription
            }
            downloadRunning = false
        }
    }

    // MARK: Connections

    /// Run "Test connection" against the draft and publish the per-endpoint dots.
    func testConnections() async {
        let r = await controller.testConnections(draft)
        let d = await controller.diagnoseConnections(draft, r)
        diag = ConnectionDiagnosis(whisperx: d.whisperx, server: d.server, local: d.local)
        lanWarningHosts = await controller.localUnreachableHosts(draft, r)
    }

    /// A "not running on this Mac" (loopback) result is expected on a machine
    /// without Ollama installed — amber guidance, never a red failure.
    var ollamaNotRunningLocally: Bool {
        diag.server == .loopbackDown || diag.local == .loopbackDown
    }

    /// Labels of endpoints that failed as plain remote/URL problems (no LAN or
    /// loopback story) — they get the generic one-liner.
    var remoteDownLabels: String? {
        var labels: [String] = []
        if diag.whisperx == .remoteDown { labels.append("WhisperX") }
        if diag.server == .remoteDown { labels.append("Server Ollama") }
        if diag.local == .remoteDown { labels.append("Local Ollama") }
        return labels.isEmpty ? nil : labels.joined(separator: ", ")
    }

    // MARK: Saving

    /// True while the draft (or the login-item toggle, applied immediately
    /// but tracked here too) differs from what's actually active.
    var hasUnsavedChanges: Bool {
        draft != controller.config || openAtLogin != controller.openAtLogin
    }

    func save() {
        controller.applyConfig(draft)
        saved = true
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            saved = false
        }
    }

    func revert() {
        draft = controller.config
        openAtLogin = controller.openAtLogin
    }

    /// Window closing (titlebar close, Cmd-W, quit) must not lose edits the user
    /// forgot to Save — persist them and note it in the activity log.
    func saveIfNeededOnClose() {
        if draft != controller.config {
            controller.applyConfigOnClose(draft)
        }
    }

    /// A reused window (SettingsWindowController keeps one instance alive across
    /// opens) must never show a confirmation left over from the previous visit.
    func windowAppeared() {
        saved = false
        #if EDITION_DIRECT
        autoUpdates = controller.updater?.automaticallyChecksForUpdates ?? true
        #endif
    }
}
