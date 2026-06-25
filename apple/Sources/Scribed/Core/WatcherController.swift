import Foundation
import AppKit
import ScribedCore

/// Menu-bar controller — the GUI-agnostic core, mirroring the Python
/// `WatcherController`. Owns config, the scan loop, status, the deferred set,
/// and the manual actions. Heavy work runs off the main actor inside the
/// (nonisolated) ScribedCore pipeline; this class only marshals state + UI.
@MainActor
final class WatcherController: ObservableObject {
    @Published private(set) var status = "Idle"
    @Published var isPaused = false
    @Published private(set) var allowLocalOllama: Bool
    @Published private(set) var watchIntervalSeconds: Int

    private(set) var config: Config
    private let deps: PipelineDeps
    private let notifier = Notifier()
    private let firstRun: Bool

    private var isScanning = false
    private var deferredBases: Set<String> = []
    private var lastDone: (base: String, note: URL?, transcript: URL?)?
    private var scanTask: Task<Void, Never>?

    static let intervalChoices = [10, 20, 60, 300]

    init(deps: PipelineDeps = .live()) {
        self.deps = deps
        let url = Config.defaultConfigURL
        self.firstRun = !FileManager.default.fileExists(atPath: url.path)
        var cfg = (try? Config.load(from: url)) ?? Config()
        cfg.applyEnvOverrides()
        self.config = cfg
        self.watchIntervalSeconds = cfg.watchIntervalSeconds
        self.allowLocalOllama = cfg.summarise.allowLocalFallback
        clearStaleProcessing()
        start()
    }

    // MARK: Lifecycle

    private func start() {
        notifier.requestAuthorization()
        scanTask = Task { [weak self] in await self?.runAfterLaunch() }
    }

    private func runAfterLaunch() async {
        applySandboxFoldersIfNeeded()
        if firstRun {
            openAppSettings()
            notifier.notify(title: "Welcome to Scribed",
                            body: "Configure your WhisperX & Ollama servers to begin.")
        }
        while !Task.isCancelled {
            if !isPaused { await scanOnce() }
            try? await Task.sleep(nanoseconds: UInt64(max(1, watchIntervalSeconds)) * 1_000_000_000)
        }
    }

    // MARK: Scanning

    private func store() -> ScribedState.Store? {
        let workDir = Config.resolvePath(config.workDir)
        let notesDir = Config.resolvePath(config.notesDir)
        return try? ScribedState.Store(
            stateDir: workDir.appendingPathComponent(".state"), notesDir: notesDir)
    }

    private func clearStaleProcessing() { store()?.clearStaleProcessing() }

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
        let pending = ScribedState.iterPending(
            recordingsDir: Config.resolvePath(cfg.recordingsDir), state: store)
        if pending.isEmpty {
            if !isPaused { status = "Idle" }
            return
        }
        for path in pending {
            status = "Processing \(path.lastPathComponent)…"
            let result = await Pipeline.processOne(path: path, config: cfg, deps: deps)
            handle(result)
        }
    }

    private func handle(_ result: ProcessResult) {
        switch result.status {
        case .done:
            status = "Last note: \(result.base)"
            deferredBases.remove(result.base)
            lastDone = (result.base, result.notePath, result.transcriptPath)
            notifier.notify(title: "✅ Transcribed & summarised",
                            body: "\(result.base) — note ready.")
        case .deferredNeedLocal:
            status = "Needs local Ollama"
            if !deferredBases.contains(result.base) {
                deferredBases.insert(result.base)
                notifier.notify(title: "Server Ollama offline",
                                body: "Enable ‘Use local Ollama’ to process \(result.base).")
            }
        case .failed:
            status = "Failed: \(result.base)"
            notifier.notify(title: "Processing failed", body: "\(result.base): \(result.message)")
        case .skipped:
            break
        }
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
            notifier.notify(title: "No transcript yet", body: "Process a recording first.")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        notifier.notify(title: "Transcript copied", body: "\(lastDone?.base ?? "") is on the clipboard.")
    }

    func openLastNote() {
        guard let note = lastDone?.note, FileManager.default.fileExists(atPath: note.path) else {
            notifier.notify(title: "No note yet", body: "Process a recording first.")
            return
        }
        NSWorkspace.shared.open(note)
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

    /// Persist + apply a full config from the settings window.
    func applyConfig(_ newConfig: Config) {
        let wasAllowed = config.summarise.allowLocalFallback
        config = newConfig
        watchIntervalSeconds = newConfig.watchIntervalSeconds
        allowLocalOllama = newConfig.summarise.allowLocalFallback
        persist()
        if newConfig.summarise.allowLocalFallback && !wasAllowed { deferredBases.removeAll() }
    }

    func testConnections(_ cfg: Config) async -> (whisperx: Bool, ollamaServer: Bool, ollamaLocal: Bool) {
        let whisper = WhisperXClient()
        let ollama = OllamaClient()
        async let whisperxOK = whisper.reachable(cfg.transcribe.whisperxURL)
        async let serverOK = ollama.reachable(cfg.summarise.server.url)
        async let localOK = ollama.reachable(cfg.summarise.local.url)
        return (await whisperxOK, await serverOK, await localOK)
    }

    private func persist() {
        try? Config.save(config, to: Config.defaultConfigURL)
    }
}
