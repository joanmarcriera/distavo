import SwiftUI
import DistavoCore
import DistavoEmbedded

/// Native settings window — replaces the Python localhost settings server.
/// Edits a draft Config and applies it to the controller on Save.
struct SettingsView: View {
    let controller: WatcherController

    @State private var draft: Config
    @State private var openAtLogin: Bool
    @State private var diag: (whisperx: NetworkScope.EndpointDiagnosis?,
                              server: NetworkScope.EndpointDiagnosis?,
                              local: NetworkScope.EndpointDiagnosis?) = (nil, nil, nil)
    @State private var showingPermissions = false
    @State private var lanWarningHosts: [String] = []
    @State private var saved = false
    #if EDITION_DIRECT
    @State private var autoUpdates = true
    #endif
    @State private var modelsOnDisk = EmbeddedModelStore.hasDownloadedModels()
        ? EmbeddedModelStore.diskUsageLabel() : nil

    private static let models = ["tiny", "base", "small", "medium", "large-v2", "large-v3"]
    private let embeddedSupported = HardwareProbe.supportsEmbeddedTranscription

    /// The catalog, plus a synthetic entry if the saved code isn't recognised
    /// (e.g. a past typo like "esp"), so the existing value stays selected and
    /// visible rather than silently changing — the user can then pick a real one.
    /// `"auto"` (Distavo's own detect-per-meeting choice) is recognised too, so
    /// it doesn't get flagged as a stray code.
    private var languageChoices: [WhisperLanguage] {
        let code = draft.transcribe.language
        if code.isEmpty || code == EmbeddedModelCatalog.automaticID
            || WhisperLanguageCatalog.language(forCode: code) != nil {
            return WhisperLanguageCatalog.all
        }
        return [WhisperLanguage(code: code, englishName: "\(code) — not a standard code")]
            + WhisperLanguageCatalog.all
    }

    /// Models this Mac's memory can actually run (spec §6 gate), plus any the
    /// benchmark has shown to run here (Vikunja #2160).
    private var selectableIDs: Set<String> {
        Set(EmbeddedModelCatalog.selectable(measuredOK: Benchmark.measuredOK(controller.config.benchmark)).map(\.id))
    }
    /// Whether this Mac can run the BSC Catalan family — both `bsc-los` and
    /// `bsc-ca-3370h` share the same 16 GB floor, so one check governs both the
    /// "Preferred Catalan model" picker's visibility and what "Download now" fetches.
    private var bscSelectable: Bool { selectableIDs.contains("bsc-los") }
    /// The Model picker's rows: selectable catalog entries, plus a synthetic one
    /// when the stored id is neither Automatic nor selectable — a low-memory Mac
    /// may have an explicit `bsc-los` chosen before the memory floor existed, or
    /// the id may be hand-edited/stale. Mirrors `languageChoices`: the existing
    /// value stays selected and visible instead of the Picker landing on nothing.
    private var modelChoices: [EmbeddedModel] {
        let stored = draft.transcribe.embeddedModel
        // Pack-only models stay out of the picker until their pack is switched on
        // (Vikunja #2124) — otherwise every language adds a 3 GB row nobody asked for.
        let enabledPackModels = Set(draft.transcribe.enabledLanguagePacks.flatMap(\.modelIDs))
        let selectable = EmbeddedModelCatalog.models.filter {
            selectableIDs.contains($0.id)
                && (!EmbeddedModelCatalog.packModelIDs.contains($0.id) || enabledPackModels.contains($0.id) || $0.id == stored)
        }
        guard !EmbeddedModelCatalog.isAutomatic(stored), !selectableIDs.contains(stored) else {
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
    /// What "Download now" fetches for the current choice (spec §5.10).
    private var downloadSet: [String] {
        if EmbeddedModelCatalog.isAutomatic(draft.transcribe.embeddedModel) {
            var ids = ["parakeet-tdt-v3"]
            if bscSelectable { ids.append(draft.transcribe.effectivePreferredCatalanModel) }
            // Enabled language packs this Mac can run (Vikunja #2124).
            for pack in draft.transcribe.enabledLanguagePacks {
                ids += pack.modelIDs.filter { selectableIDs.contains($0) && !ids.contains($0) }
            }
            return ids
        }
        return [draft.transcribe.embeddedModel]
    }
    /// M7: only what "Download now" would actually fetch — a model already on
    /// disk (or the detector, already downloaded) must not inflate the total
    /// the button shows before starting.
    private var downloadTotalMB: Int {
        let modelsMB = downloadSet
            .map { EmbeddedModelCatalog.model(id: $0) }
            .filter { !EmbeddedModelStore.isDownloaded($0) }
            .map(\.downloadMB)
            .reduce(0, +)
        let needsDetector = EmbeddedModelCatalog.isAutomatic(draft.transcribe.embeddedModel)
            && !EmbeddedModelStore.isDetectorDownloaded()
        return modelsMB + (needsDetector ? 77 : 0)
    }

    /// Opt-in language packs (Vikunja #2124): one toggle per pack. A pack whose
    /// model this Mac cannot run (memory floor) is shown disabled with the reason,
    /// never silently dropped, so the user learns why Hebrew still goes to Whisper.
    @ViewBuilder private var languagePacksRows: some View {
        HStack {
            Text("Language packs").font(.callout)
            HelpButton(text: "Community fine-tunes of Whisper for languages the stock models handle poorly. Switch one on and Distavo routes meetings in that language to it (downloaded once, like every other model). Off by default; nothing changes for languages you have not switched on.")
        }
        ForEach(EmbeddedModelCatalog.languagePacks) { pack in
            let runnable = pack.modelIDs.allSatisfy { selectableIDs.contains($0) }
            let floor = pack.modelIDs.map { EmbeddedModelCatalog.model(id: $0).minimumMemoryGB }.max() ?? 0
            HStack {
                Toggle(isOn: packBinding(pack.id)) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(pack.displayName) — \(pack.languageLabel) · \(pack.downloadMB) MB")
                        Text(runnable ? pack.credit : "\(pack.credit) · needs \(floor) GB of memory")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .disabled(!runnable)
            }
        }
    }

    /// Membership of `pack` in `transcribe.language_packs`, kept in catalog order.
    private func packBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { draft.transcribe.languagePacks.contains(id) },
            set: { on in
                var ids = Set(draft.transcribe.languagePacks)
                if on { ids.insert(id) } else { ids.remove(id) }
                draft.transcribe.languagePacks = EmbeddedModelCatalog.languagePacks.map(\.id).filter { ids.contains($0) }
            })
    }

    init(controller: WatcherController) {
        self.controller = controller
        _draft = State(initialValue: controller.config)
        _openAtLogin = State(initialValue: controller.openAtLogin)
    }

    var body: some View {
        Form {
            Section("Getting started") {
                Text("Distavo watches a folder and turns each new recording into a Markdown note. Transcription runs right on this Mac (or on your own WhisperX server); summaries use your own Ollama. Nothing is ever sent to a cloud service.")
                    .font(.callout).foregroundStyle(.secondary)
                folderRow("Watches", Config.resolvePath(draft.recordingsDir).path)
                folderRow("Writes notes to", Config.resolvePath(draft.notesDir).path)
                folderRow("Working files", Config.resolvePath(draft.workDir).path)
                Text("These folders are created automatically if they don't exist. Tip: set the watch folder to an iCloud Drive / Google Drive folder so recordings made elsewhere are processed once they finish syncing.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("General") {
                Picker("Watch interval", selection: $draft.watchIntervalSeconds) {
                    ForEach(WatcherController.intervalChoices, id: \.self) { secs in
                        Text(WatcherController.intervalLabel(secs)).tag(secs)
                    }
                }
                HStack {
                    TextField("Watch folder", text: $draft.recordingsDir)
                    HelpButton(text: "Distavo watches this folder and turns each new recording into a note. Drop files here, or point it at an iCloud Drive / Google Drive folder so recordings sync in automatically.")
                }
                TextField("Notes folder", text: $draft.notesDir)
                TextField("Work folder", text: $draft.workDir)
                TextField("Note owner", text: $draft.noteOwner)
                TextField("Your speaker label", text: $draft.userSpeaker)
                Toggle("Open at login", isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { _, enabled in
                        controller.setOpenAtLogin(enabled)
                    }
            }

            Section("Recordings") {
                if MeetingCaptureController.isSupported {
                    HStack {
                        Toggle("Ask who was in the meeting when a recording stops",
                               isOn: $draft.askSpeakersOnStop)
                        HelpButton(text: "After you stop the built-in recorder, Distavo asks how many people spoke, your role and who the others were, and hands that to the summariser so the notes name the speakers and the follow-up email is written from your side. Skip the question any time.")
                    }
                }
                HStack {
                    Stepper("Ignore recordings shorter than \(draft.minRecordingSeconds) s",
                            value: $draft.minRecordingSeconds, in: 0...120, step: 5)
                    HelpButton(text: "A recording under this length is set aside instead of producing an empty note — the menu offers to delete it. Set to 0 to transcribe everything.")
                }
                HStack {
                    Toggle("Shrink recordings once the note is written",
                           isOn: $draft.compactRecordingsAfterNote)
                    HelpButton(text: "The built-in recorder keeps a 48 kHz stereo take (about 1.4 GB per hour). Once the note is written, Distavo replaces WAV recordings with the 16 kHz mono copy the transcriber used — about 20x smaller. Other formats are left alone.")
                }
                HStack {
                    Picker("When a recording finishes", selection: $draft.openWhenDone) {
                        Text("Off").tag(OpenWhenDone.off)
                        Text("Open the note").tag(OpenWhenDone.note)
                        Text("Open the transcript").tag(OpenWhenDone.transcript)
                    }
                    HelpButton(text: "Automatically open the finished note (or its cleaned transcript) as soon as a recording is processed, instead of waiting to open it from the menu.")
                }
            }

            Section("Transcription") {
                if embeddedSupported {
                    HStack {
                        Picker("Engine", selection: $draft.transcribe.backend) {
                            Text("Built-in (this Mac)").tag("embedded")
                            Text("WhisperX server").tag("server")
                        }
                        HelpButton(text: "‘Built-in’ transcribes on this Mac with Whisper — no server or install needed; the model downloads once. ‘WhisperX server’ sends audio to a WhisperX URL you run yourself.")
                    }
                } else {
                    Text("Built-in transcription needs an Apple Silicon Mac — this Mac uses a WhisperX server.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if draft.transcribe.backend == "embedded" && embeddedSupported {
                    // `.disabled(...)` on a Picker's Text does not disable the menu
                    // item on macOS, so unselectable entries (this Mac's memory is
                    // below the model's floor) are filtered out of the list instead
                    // and named in the caption below rather than shown as a dead row.
                    // `modelChoices` still surfaces the current value even when it's
                    // one of those unselectable/unknown ids, so the Picker's selection
                    // always matches a real tag.
                    Picker("Model", selection: $draft.transcribe.embeddedModel) {
                        Text("Automatic (recommended)").tag(EmbeddedModelCatalog.automaticID)
                        Divider()
                        ForEach(modelChoices) { m in
                            Text(selectableIDs.contains(m.id) ? "\(m.displayName) — \(m.downloadLabel)" : m.displayName)
                                .tag(m.id)
                        }
                    }
                    if EmbeddedModelCatalog.isAutomatic(draft.transcribe.embeddedModel) {
                        Text("Distavo listens to three short windows, picks the engine for the language it hears — Catalan, Spanish and their mix on the Barcelona models, 25 other European languages on the fast Parakeet engine, everything else on Whisper (or a language pack you switch on below) — and downloads what it needs once.")
                            .font(.caption).foregroundStyle(.secondary)
                        if bscSelectable {
                            Picker("Preferred Catalan model", selection: $draft.transcribe.preferredCatalanModel) {
                                Text("Català · Castellà · Galego · Euskara (Languages of Spain)").tag("bsc-los")
                                Text("Català only (3,370 hours)").tag("bsc-ca-3370h")
                            }
                        }
                        languagePacksRows
                    } else {
                        let m = EmbeddedModelCatalog.model(id: draft.transcribe.embeddedModel)
                        Text("\(m.detail) \(m.ramLabel).").font(.caption).foregroundStyle(.secondary)
                    }
                    BenchmarkButton(controller: controller)
                    let unselectable = EmbeddedModelCatalog.models.filter { !selectableIDs.contains($0.id) }
                    if !unselectable.isEmpty {
                        Text("Not offered on this Mac (needs more memory): \(unselectable.map(\.displayName).joined(separator: ", ")).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ModelDownloadButton(controller: controller, modelIDs: downloadSet, totalMB: downloadTotalMB)
                    HStack {
                        if let usage = modelsOnDisk {
                            Text("Models on disk: \(usage)").font(.callout)
                            Button("Remove downloaded models") {
                                Task { try? await ModelCoordinator.shared.removeAllModels(); modelsOnDisk = nil }
                            }
                        } else {
                            Text("No models downloaded yet. Distavo keeps every model it downloads in Application Support/Distavo/models; removing that folder removes all of them (macOS keeps its own small Core ML caches separately).")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    HStack {
                        TextField("WhisperX URL", text: $draft.transcribe.whisperxURL)
                        ServerHelpButton(kind: .whisperx)
                    }
                    Picker("Model", selection: $draft.transcribe.model) {
                        ForEach(Self.models, id: \.self) { Text($0).tag($0) }
                    }
                }

                Picker("Language", selection: $draft.transcribe.language) {
                    // C1: this row drives EngineRouter's per-meeting engine
                    // choice (spec §5.2) — a choice that only exists on the
                    // built-in engine. WhisperXClient maps "auto" to "" rather
                    // than ever sending it to the server, so offering this row
                    // to a WhisperX user would silently change what language
                    // WhisperX is told (the server has no per-language engine
                    // to route to). Show it only for the built-in engine.
                    if draft.transcribe.backend == "embedded" && embeddedSupported {
                        Text("Automatic — pick the engine by language (recommended)").tag(EmbeddedModelCatalog.automaticID)
                    } else if draft.transcribe.language == EmbeddedModelCatalog.automaticID {
                        // A WhisperX user whose stored language is still "auto"
                        // (set while on the built-in engine, or a fresh
                        // install's default) — keep it selected and visible
                        // instead of the Picker landing on nothing or silently
                        // switching values, same as the unrecognised-code
                        // synthetic row in `languageChoices` below.
                        Text("Automatic — built-in engine only; pick a language for WhisperX").tag(EmbeddedModelCatalog.automaticID)
                    }
                    // Distinct from the catalog's own "Auto-detect" (tag "", below):
                    // the row above drives EngineRouter's per-meeting engine choice;
                    // "Auto-detect" is Whisper's single-pass guess within whichever
                    // model ends up chosen.
                    ForEach(languageChoices) { lang in
                        Text(lang.code.isEmpty ? "Auto-detect within the chosen model" : lang.englishName)
                            .tag(lang.code)
                    }
                }
                if let detected = controller.lastDetectedLanguages {
                    Text("Last recording: detected \(detected).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Stepper("Number of speakers: \(draft.transcribe.numSpeakers)",

                            value: $draft.transcribe.numSpeakers, in: 1...10)
                    HelpButton(text: "Roughly how many people are speaking. Helps separate and label speakers.")
                }
                HStack {
                    Toggle("Diarize (separate speakers)", isOn: $draft.transcribe.diarize)
                    HelpButton(text: "Label who said what (SPEAKER_00, SPEAKER_01…). Turn off for a single-speaker recording.")
                }
            }

            Section(draft.summarise.embeddedEnabled ? "Summarisation" : "Summarisation (Ollama)") {
                if #available(macOS 26, *), EmbeddedSummariser.unavailableReason() == nil
                    || draft.summarise.embeddedEnabled {
                    HStack {
                        Toggle("Offer on-device summaries (Apple Intelligence, preview)",
                               isOn: $draft.summarise.embeddedEnabled)
                        HelpButton(text: "Adds an ‘On this Mac (Apple Intelligence)’ backend below. It needs no server, but Apple’s on-device model has a small context window, so long meetings are summarised in parts and the notes are less detailed than a capable Ollama model’s. Off by default in this version; switch it on to try it.")
                    }
                }
                HStack {
                    Picker("Backend", selection: $draft.summarise.backend) {
                        Text("Server (GPU)").tag("server")
                        Text("Local Mac").tag("local")
                        // Opt-in preview (summarise.embedded_enabled); hidden
                        // otherwise so the default install is unchanged.
                        if draft.summarise.embeddedEnabled {
                            Text("Built-in (this Mac)").tag("embedded")
                        }
                    }
                    HelpButton(text: draft.summarise.embeddedEnabled
                        ? "‘Server (GPU)’ uses the Server Ollama URL; ‘Local Mac’ uses the Local Ollama URL on this Mac. ‘Built-in’ summarises with Apple Intelligence on this Mac — no server or install, but it handles long meetings in several passes and is less detailed than Ollama."
                        : "‘Server (GPU)’ uses the Server Ollama URL; ‘Local Mac’ uses the Local Ollama URL on this Mac. If the server is offline you can allow the local fallback below.")
                }
                if draft.summarise.embeddedEnabled && draft.summarise.backend == "embedded" {
                    if let reason = EmbeddedSummariser.unavailableReason() {
                        Text("⚠︎ \(reason.localizedDescription)")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Summarising on this Mac with Apple Intelligence — nothing leaves the device and no Ollama is needed. Long recordings are summarised in several passes, which is less detailed than an Ollama model.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    TextField("Server Ollama URL", text: $draft.summarise.server.url)
                    ServerHelpButton(kind: .ollama)
                }
                TextField("Server model", text: $draft.summarise.server.model)
                HStack {
                    Picker("Prompt", selection: $draft.summarise.promptStyle) {
                        Text("Facts first (recommended)").tag(Prompt.Style.factsFirst)
                        Text("Classic").tag(Prompt.Style.classic)
                    }
                    HelpButton(text: "‘Facts first’ makes the model identify the speakers with evidence and list every number, date, company and rate it heard (with UK-contracting corrections such as “8.50 per day” → £850) before writing the notes, and keeps that ledger in the note as an audit trail. Best with a capable model such as gemma4:26b. ‘Classic’ is the shorter original prompt. On-device (Apple Intelligence) summaries always use Classic.")
                }
                HStack {
                    Picker("Write notes in", selection: $draft.summarise.noteLanguage) {
                        Text("Match the meeting language").tag("auto")
                        Text("English").tag("en")
                    }
                    HelpButton(text: "‘Match the meeting language’ writes the note in Catalan or Spanish when that's the meeting's dominant detected language (section headings stay in English); any other detected language still gets English notes. ‘English’ always writes English notes, whatever was spoken. On-device (Apple Intelligence) summaries always write English.")
                }
                HStack {
                    TextField("Local Ollama URL", text: $draft.summarise.local.url)
                    ServerHelpButton(kind: .ollama)
                }
                TextField("Local model", text: $draft.summarise.local.model)
                HStack {
                    Toggle("Allow local Ollama fallback (loads this Mac)",
                           isOn: $draft.summarise.allowLocalFallback)
                    HelpButton(text: "If the Server Ollama is unreachable, summarise on this Mac instead (uses local CPU/RAM).")
                }
            }

            Section("Connections") {
                HStack(spacing: 16) {
                    if draft.transcribe.backend != "embedded" {
                        dot("WhisperX", diag.whisperx)
                    }
                    dot("Server Ollama", diag.server)
                    dot("Local Ollama", diag.local)
                }
                HStack {
                    Button("Test connection") {
                        Task {
                            let r = await controller.testConnections(draft)
                            let d = await controller.diagnoseConnections(draft, r)
                            diag = (d.whisperx, d.server, d.local)
                            lanWarningHosts = await controller.localUnreachableHosts(draft, r)
                        }
                    }
                    Button("Check permissions…") { showingPermissions = true }
                }
                if ollamaNotRunningLocally {
                    localOllamaGuidance
                }
                if let remote = remoteDownLabels {
                    Text("Can’t reach \(remote) — check the server is running and the URL is correct.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !lanWarningHosts.isEmpty {
                    lanPermissionWarning
                }
            }

            #if EDITION_DIRECT
            Section("Updates") {
                Toggle("Automatically check for updates", isOn: $autoUpdates)
                    .onChange(of: autoUpdates) { _, on in
                        controller.updater?.automaticallyChecksForUpdates = on
                    }
                Button("Check for updates now…") { controller.updater?.checkForUpdates() }
            }
            #endif
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) { bottomBar }
        .frame(width: 520, height: 640)
        .sheet(isPresented: $showingPermissions) { PermissionsView(config: draft) }
        .onAppear {
            // A reused window (SettingsWindowController keeps one instance
            // alive across opens) must never show a confirmation left over
            // from the previous visit.
            saved = false
            #if EDITION_DIRECT
            autoUpdates = controller.updater?.automaticallyChecksForUpdates ?? true
            #endif
        }
        .onDisappear {
            // The window closing (titlebar close, Cmd-W, quit) must not lose
            // edits the user forgot to click Save for — persist them silently
            // and note it in the activity log since there's no window left to
            // show a confirmation in.
            if draft != controller.config {
                controller.applyConfigOnClose(draft)
            }
        }
    }

    /// True while the draft (or the login-item toggle, applied immediately
    /// but tracked here too) differs from what's actually active — drives the
    /// "Unsaved changes" label and enables/disables Revert and Save.
    private var hasUnsavedChanges: Bool {
        draft != controller.config || openAtLogin != controller.openAtLogin
    }

    /// Pinned bottom bar (`.safeAreaInset`) so Save is always visible without
    /// scrolling the Form to the bottom — the trigger for this fix was a
    /// missed Save after changing Language further up the form.
    private var bottomBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                if hasUnsavedChanges {
                    Text("Unsaved changes").font(.callout).foregroundStyle(.secondary)
                } else if saved {
                    Text("Saved — applied immediately.").foregroundStyle(.green).font(.callout)
                }
                Spacer()
                Button("Revert") {
                    draft = controller.config
                    openAtLogin = controller.openAtLogin
                }
                .disabled(!hasUnsavedChanges)
                Button("Save") {
                    controller.applyConfig(draft)
                    saved = true
                    Task {
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        saved = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!hasUnsavedChanges)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
        .background(.regularMaterial)
    }

    /// Shown after a failed Test Connections when the unreachable server is on the
    /// LAN — the classic missing/stale Local Network permission case.
    private var lanPermissionWarning: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Can’t reach \(lanWarningHosts.joined(separator: ", ")) — "
                     + "\(lanWarningHosts.count == 1 ? "it is" : "they are") on your local network. "
                     + "This is usually the macOS Local Network permission.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Fix permissions…") { showingPermissions = true }
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }

    private func folderRow(_ label: String, _ path: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(path)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .lineLimit(1).truncationMode(.middle)
        }
    }

    /// A "not running on this Mac" (loopback) result is expected on a machine
    /// without Ollama installed — amber guidance, never a red failure. Red is
    /// reserved for a configured LAN/remote server that doesn't answer.
    private func dot(_ label: String, _ state: NetworkScope.EndpointDiagnosis?) -> some View {
        let color: Color
        switch state {
        case .reachable: color = .green
        case .loopbackDown: color = .orange
        case .lanDown, .remoteDown: color = .red
        case .notConfigured, nil: color = .gray
        }
        return HStack(spacing: 6) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(label).font(.callout)
        }
    }

    private var ollamaNotRunningLocally: Bool {
        diag.server == .loopbackDown || diag.local == .loopbackDown
    }

    /// Labels of endpoints that failed as plain remote/URL problems (no LAN or
    /// loopback story) — they get the generic one-liner.
    private var remoteDownLabels: String? {
        var labels: [String] = []
        if diag.whisperx == .remoteDown { labels.append("WhisperX") }
        if diag.server == .remoteDown { labels.append("Server Ollama") }
        if diag.local == .remoteDown { labels.append("Local Ollama") }
        return labels.isEmpty ? nil : labels.joined(separator: ", ")
    }

    /// Shown when an Ollama endpoint on this Mac isn't answering: on a machine
    /// without Ollama installed that is the normal starting state, so explain
    /// what still works and what to do — don't present it as a failure.
    private var localOllamaGuidance: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle.fill").foregroundStyle(.orange)
            Text("Ollama isn’t running on this Mac — that’s the normal starting point. Distavo still records and transcribes; notes are completed once a summariser is available. Install Ollama from ollama.com and run it, or point “Server Ollama” at one on your network.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }
}
