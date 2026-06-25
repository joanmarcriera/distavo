import Foundation

/// Skeleton of the menu-bar controller. Mirrors the Python `WatcherController`
/// (status line, pause, interval, local-Ollama toggle, manual actions). The real
/// scan loop + pipeline are injected in Phase C; these methods are stubs for now.
@MainActor
final class WatcherController: ObservableObject {
    @Published private(set) var status: String = "Idle"
    @Published var isPaused: Bool = false
    @Published var allowLocalOllama: Bool = false
    @Published private(set) var watchIntervalSeconds: Int = 20

    static let intervalChoices: [Int] = [10, 20, 60, 300]

    // MARK: Manual actions (Phase C wires these to the real pipeline)

    func processNow() { status = "Processing…" }
    func scanOnce() {}
    func copyLastTranscript() {}
    func openLastNote() {}
    func openNotesFolder() {}
    func openRecordingsFolder() {}

    // MARK: Settings toggles

    func setInterval(_ seconds: Int) { watchIntervalSeconds = seconds }

    func togglePause() {
        isPaused.toggle()
        status = isPaused ? "Paused" : "Idle"
    }

    func toggleAllowLocal() { allowLocalOllama.toggle() }
}
