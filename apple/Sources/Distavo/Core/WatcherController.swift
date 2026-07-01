import Foundation
import AppKit
import DistavoCore
import DistavoEmbedded

/// Menu-bar controller — the GUI-agnostic core, mirroring the Python
/// `WatcherController`. Owns config, the scan loop, status, the deferred set,
/// and the manual actions. Heavy work runs off the main actor inside the
/// (nonisolated) DistavoCore pipeline; this class only marshals state + UI.
@MainActor
final class WatcherController: ObservableObject {
    /// Drives the menu-bar badge: nothing / processing (amber) / new note (green).
    enum Activity { case idle, processing, done }

    @Published private(set) var status = "Idle"
    @Published private(set) var activity: Activity = .idle
    @Published var isPaused = false
    @Published private(set) var allowLocalOllama: Bool
    @Published private(set) var watchIntervalSeconds: Int
    @Published private(set) var hasLastNote = false
    @Published private(set) var lastError: String?
    @Published private(set) var recentActivity: [String] = []

    private(set) var config: Config
    private let deps: PipelineDeps
    private let notifier = Notifier()
    private let needsOnboarding: Bool
    private let activityLog = ActivityLog()

    private var isScanning = false
    private var processingActive = false
    private var unseenDone = false
    private var deferredBases: Set<String> = []
    private var lastDone: (base: String, note: URL?, transcript: URL?)?
    private var scanTask: Task<Void, Never>?

    static let intervalChoices = [10, 20, 60, 300]
    /// "60s" → "1m"; shared by the menu and the settings picker.
    static func intervalLabel(_ seconds: Int) -> String {
        seconds % 60 == 0 ? "\(seconds / 60)m" : "\(seconds)s"
    }
    private static let onboardedKey = "distavo.didOnboard"
    private static let localNetWarnedKey = "distavo.didWarnLocalNetwork"

    init(deps: PipelineDeps = .appLive()) {
        self.deps = deps
        self.needsOnboarding = !UserDefaults.standard.bool(forKey: Self.onboardedKey)
        // Fresh installs default to the on-device engine sized for this Mac;
        // existing config files keep whatever backend they already use.
        var cfg = (try? Config.load(from: Config.defaultConfigURL,
                                    fresh: .recommendedForThisMac())) ?? Config()
        // A config carried over from another Mac may say "embedded" on
        // hardware that can't run it (Intel) — fall back to the server backend
        // rather than failing every recording.
        if cfg.transcribe.backend == "embedded" && !HardwareProbe.supportsEmbeddedTranscription {
            cfg.transcribe.backend = "server"
        }
        cfg.applyEnvOverrides()
        self.config = cfg
        self.watchIntervalSeconds = cfg.watchIntervalSeconds
        self.allowLocalOllama = cfg.summarise.allowLocalFallback
        clearStaleProcessing()
        recentActivity = activityLog.recent(12)
        log("Distavo started")
        wireEmbeddedProgress()
        start()
    }

    /// Surface embedded-engine phases (model download, transcribing,
    /// diarizing) in the menu status and the activity log.
    private func wireEmbeddedProgress() {
        Task {
            await EmbeddedTranscriber.shared.setProgressHandler { [weak self] message in
                Task { @MainActor in
                    guard let self, self.processingActive else { return }
                    self.status = message
                    self.log(message)
                }
            }
        }
    }

    // MARK: Lifecycle

    private func start() {
        notifier.requestAuthorization()
        scanTask = Task { [weak self] in await self?.runAfterLaunch() }
    }

    private func runAfterLaunch() async {
        applySandboxFoldersIfNeeded()
        if needsOnboarding {
            SettingsWindowController.shared.show(self)
            notifier.notify(title: "Welcome to Distavo",
                            body: config.transcribe.backend == "embedded"
                                ? "Transcription runs on this Mac out of the box. Add your Ollama server (for summaries) in Settings to begin."
                                : "Choose your folders and point Distavo at your WhisperX & Ollama servers to begin.")
            UserDefaults.standard.set(true, forKey: Self.onboardedKey)
        }
        maybeWarnLocalNetwork()
        while !Task.isCancelled {
            if !isPaused { await scanOnce() }
            try? await Task.sleep(nanoseconds: UInt64(max(1, watchIntervalSeconds)) * 1_000_000_000)
        }
    }

    func showSettings() { SettingsWindowController.shared.show(self) }

    /// Open the timestamped activity log in the user's default text viewer.
    func openLog() { NSWorkspace.shared.open(activityLog.url) }

    private func log(_ message: String) {
        let entry = activityLog.append(message)
        recentActivity.append(entry)
        if recentActivity.count > 12 { recentActivity.removeFirst(recentActivity.count - 12) }
    }

    private func refreshActivity() {
        if processingActive { activity = .processing }
        else if unseenDone { activity = .done }
        else { activity = .idle }
    }

    // MARK: Scanning

    private func store() -> DistavoState.Store? {
        let workDir = Config.resolvePath(config.workDir)
        let notesDir = Config.resolvePath(config.notesDir)
        return try? DistavoState.Store(
            stateDir: workDir.appendingPathComponent(".state"), notesDir: notesDir)
    }

    private func clearStaleProcessing() { store()?.clearStaleProcessing() }

    /// Warn (once) that macOS is about to ask for Local Network permission, so the
    /// user understands the prompt and clicks Allow. Only when a LAN server is set.
    private func maybeWarnLocalNetwork() {
        guard NetworkScope.usesLocalNetwork(config),
              !UserDefaults.standard.bool(forKey: Self.localNetWarnedKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.localNetWarnedKey)
        let alert = NSAlert()
        alert.messageText = "Distavo needs Local Network access"
        alert.informativeText = """
        Your WhisperX/Ollama servers are on your local network, so macOS will now ask \
        permission to find devices on your network. Please click “Allow” — Distavo only uses \
        this to reach the servers you configured. You can change it later in \
        System Settings → Privacy & Security → Local Network.
        """
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// In the sandboxed edition, point the recordings/notes folders at the
    /// user-granted (bookmarked) locations. No-op elsewhere.
    private func applySandboxFoldersIfNeeded() {
        let access = SandboxFolders.ensureAccess()
        var changed = false
        if let recordings = access.recordings { config.recordingsDir = recordings.path; changed = true }
        if let notes = access.notes { config.notesDir = notes.path; changed = true }
        if changed { persist() }
    }

    /// Process all pending recordings (self-serializing so overlapping timer
    /// ticks and "Process now" can't double-process).
    func scanOnce() async {
        if isScanning { return }
        isScanning = true
        defer { isScanning = false }

        let cfg = config
        guard let store = store() else { return }
        let pending = DistavoState.iterPending(
            recordingsDir: Config.resolvePath(cfg.recordingsDir), state: store)
        if pending.isEmpty {
            if !isPaused { status = "Idle" }
            refreshActivity()
            return
        }
        processingActive = true
        refreshActivity()
        for path in pending {
            status = "Processing \(path.lastPathComponent)…"
            log("Processing \(path.lastPathComponent)")
            let result = await Pipeline.processOne(path: path, config: cfg, deps: deps)
            handle(result)
        }
        processingActive = false
        refreshActivity()
    }

    private func handle(_ result: ProcessResult) {
        switch result.status {
        case .done:
            status = "Last note: \(result.base)"
            deferredBases.remove(result.base)
            lastDone = (result.base, result.notePath, result.transcriptPath)
            hasLastNote = true
            unseenDone = true
            lastError = nil
            log("Saved note: \(result.base)")
            notifier.notify(title: "✅ Transcribed & summarised",
                            body: "\(result.base) — note ready.")
        case .deferredNeedLocal:
            status = "Needs local Ollama"
            if !deferredBases.contains(result.base) {
                deferredBases.insert(result.base)
                log("Deferred — server Ollama offline: \(result.base)")
                notifier.notify(title: "Server Ollama offline",
                                body: "Enable ‘Use local Ollama’ to process \(result.base).")
            }
        case .failed:
            status = "Failed: \(result.base)"
            lastError = "\(result.base): \(result.message)"
            log("Failed: \(result.base) — \(result.message)")
            notifier.notify(title: "Processing failed", body: "\(result.base): \(result.message)")
        case .skipped:
            break
        }
        refreshActivity()
    }

    // MARK: Manual actions (menu)

    /// "Process now" clears failed markers so every file gets retried, then scans.
    func processNow() {
        Task { [weak self] in
            guard let self else { return }
            self.store()?.retryFailed()
            await self.scanOnce()
        }
    }

    func copyLastTranscript() {
        guard let transcript = lastDone?.transcript,
              let text = try? String(contentsOf: transcript, encoding: .utf8) else {
            notifier.notify(title: "Nothing to copy yet",
                            body: "No transcript is available — process a recording first.")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        notifier.notify(title: "Transcript copied", body: "\(lastDone?.base ?? "") is on the clipboard.")
        acknowledgeNote()
    }

    func openLastNote() {
        guard let note = lastDone?.note, FileManager.default.fileExists(atPath: note.path) else {
            notifier.notify(title: "No note yet", body: "Process a recording first.")
            return
        }
        NSWorkspace.shared.open(note)
        acknowledgeNote()
    }

    /// Clear the green "new note" badge once the user has looked at the result.
    private func acknowledgeNote() {
        unseenDone = false
        refreshActivity()
    }

    func openNotesFolder() { openFolder(Config.resolvePath(config.notesDir)) }
    func openRecordingsFolder() { openFolder(Config.resolvePath(config.recordingsDir)) }

    private func openFolder(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    func togglePause() {
        isPaused.toggle()
        status = isPaused ? "Paused" : "Idle"
    }

    func setInterval(_ seconds: Int) {
        config.watchIntervalSeconds = seconds
        watchIntervalSeconds = seconds
        persist()
    }

    func toggleAllowLocal() {
        allowLocalOllama.toggle()
        config.summarise.allowLocalFallback = allowLocalOllama
        persist()
        if allowLocalOllama {
            deferredBases.removeAll()
            processNow()
        }
    }

    // MARK: Settings integration

    var openAtLogin: Bool { LoginItem.isEnabled }
    func setOpenAtLogin(_ enabled: Bool) { LoginItem.setEnabled(enabled) }

    /// Resolved folders Distavo reads/writes (shown in onboarding so the user
    /// knows what will be created).
    var resolvedFolders: (recordings: String, notes: String, work: String) {
        (Config.resolvePath(config.recordingsDir).path,
         Config.resolvePath(config.notesDir).path,
         Config.resolvePath(config.workDir).path)
    }

    /// Persist + apply a full config from the settings window.
    func applyConfig(_ newConfig: Config) {
        let wasAllowed = config.summarise.allowLocalFallback
        config = newConfig
        watchIntervalSeconds = newConfig.watchIntervalSeconds
        allowLocalOllama = newConfig.summarise.allowLocalFallback
        persist()
        if newConfig.summarise.allowLocalFallback && !wasAllowed { deferredBases.removeAll() }
        // New settings may fix a prior failure — clear failed markers and retry.
        lastError = nil
        maybeWarnLocalNetwork()
        processNow()
    }

    func testConnections(_ cfg: Config) async -> (whisperx: Bool, ollamaServer: Bool, ollamaLocal: Bool) {
        let whisper = WhisperXClient()
        let ollama = OllamaClient()
        // With the embedded engine there is no WhisperX to probe — skip the
        // TCP-timeout wait (the dot is hidden in that mode anyway).
        async let whisperxOK = cfg.transcribe.backend == "embedded"
            ? true : whisper.reachable(cfg.transcribe.whisperxURL)
        async let serverOK = ollama.reachable(cfg.summarise.server.url)
        async let localOK = ollama.reachable(cfg.summarise.local.url)
        return (await whisperxOK, await serverOK, await localOK)
    }

    private func persist() {
        try? Config.save(config, to: Config.defaultConfigURL)
    }
}
