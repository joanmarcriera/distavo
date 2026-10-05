import AVFoundation
import AppKit
import DistavoCore

// State and playback for the audio-synced transcript viewer (Vikunja #2951).
// All timeline / edit / save logic lives in DistavoCore (`TranscriptLayout`,
// `TranscriptEditing`, `TranscriptEditStore`); this class wires it to an
// AVPlayer and to the SwiftUI window. Main-actor only.

/// A note the viewer's picker can open.
struct TranscriptNote: Identifiable, Equatable {
    let base: String
    var id: String { base }
}

@MainActor
final class TranscriptViewerModel: ObservableObject {

    // MARK: Inputs (fixed for the window's life)
    let workDir: URL
    let notes: [TranscriptNote]
    /// Finds the source recording for a base (off the main thread; may walk a big folder).
    private let findSource: @Sendable (String) -> URL?
    /// Called after a successful save so the search index can pick up the new transcript.
    private let didSave: (String) -> Void
    /// Re-summarises the note from the saved transcript; returns a one-line outcome.
    private let resummarise: (String) async -> (ok: Bool, message: String)

    // MARK: Published state
    @Published private(set) var base: String = ""
    /// nil = no timed transcript for this recording (read-only plain text).
    @Published private(set) var transcript: TranscriptSegments?
    @Published private(set) var layout: TranscriptLayout?
    /// What the text view shows when there is no layout.
    @Published private(set) var plainText = ""
    /// Bumped whenever the displayed text must be replaced wholesale.
    @Published private(set) var contentID = 0
    @Published var isEditing = false { didSet { if isEditing { highlight = nil } } }
    @Published private(set) var dirty = false
    @Published private(set) var highlight: Int?
    @Published private(set) var isPlaying = false
    @Published var rate: Float = 1 { didSet { if isPlaying { player?.rate = rate } } }
    @Published private(set) var currentSeconds = 0
    @Published private(set) var durationSeconds = 0
    /// Why playback is unavailable, or nil when it works.
    @Published private(set) var playbackProblem: String?
    @Published private(set) var canRevert = false
    @Published private(set) var hasCleanTranscript = false
    @Published private(set) var busy = false
    /// One-line outcome of the last save / revert / re-summarise.
    @Published private(set) var message: String?
    /// True after a save in this session: the note no longer matches the transcript.
    @Published private(set) var noteIsStale = false

    private var editedText = ""
    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var loadGeneration = 0

    var canPlay: Bool { player != nil && playbackProblem == nil }
    var canEdit: Bool { transcript != nil }

    init(workDir: URL, notes: [TranscriptNote], initial: String?,
         findSource: @escaping @Sendable (String) -> URL?,
         didSave: @escaping (String) -> Void,
         resummarise: @escaping (String) async -> (ok: Bool, message: String)) {
        self.workDir = workDir; self.notes = notes
        self.findSource = findSource; self.didSave = didSave; self.resummarise = resummarise
        if let first = initial ?? notes.first?.base { select(first) }
    }

    // MARK: Loading

    func select(_ newBase: String) {
        guard !dirty else { return }
        teardownPlayer()
        base = newBase
        message = nil; noteIsStale = false; isEditing = false
        loadTranscript()
        loadPlayer()
    }

    private func loadTranscript() {
        let cleanURL = Pipeline.cachedTranscriptURL(workDir: workDir, base: base)
        let clean = (try? String(contentsOf: cleanURL, encoding: .utf8)) ?? ""
        hasCleanTranscript = !clean.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        canRevert = TranscriptEditStore.isModified(workDir: workDir, base: base)
        if let t = TranscriptSegments.load(workDir: workDir, base: base) {
            show(t)
        } else {
            transcript = nil; layout = nil
            plainText = clean.isEmpty ? "No transcript was saved for this note." : clean
            editedText = plainText; dirty = false
            contentID += 1
        }
    }

    private func show(_ t: TranscriptSegments) {
        transcript = t
        let l = TranscriptLayout(t)
        layout = l; plainText = l.text; editedText = l.text
        dirty = false; highlight = nil
        contentID += 1
    }

    // MARK: Editing

    /// The text view reports its full text after each (allowed) change.
    func textChanged(_ text: String) {
        editedText = text
        let isDirty = text != (layout?.text ?? plainText)
        if isDirty != dirty { dirty = isDirty }
    }

    /// Throw away unsaved edits.
    func discardChanges() {
        guard let t = transcript else { return }
        show(t); isEditing = false; message = nil
    }

    /// Write the edited transcript (all-or-nothing, originals kept). Does NOT
    /// touch the note: that is "Re-summarise".
    @discardableResult
    func save() -> Bool {
        guard dirty, let t = transcript, let l = layout else { return true }
        guard let edits = l.edits(from: editedText, original: t) else {
            message = "Could not save: the transcript structure changed. Discard the changes and try again."
            return false
        }
        let edited = TranscriptEditing.applyEdits(edits, to: t)
        do {
            try TranscriptEditStore.save(edited, workDir: workDir, base: base)
        } catch {
            message = "Not saved — nothing was changed: \(error.localizedDescription)"
            return false
        }
        show(edited)
        isEditing = false
        canRevert = TranscriptEditStore.isModified(workDir: workDir, base: base)
        hasCleanTranscript = true
        noteIsStale = true
        message = "Saved. The note still reflects the old transcript — re-summarise to rewrite it."
        didSave(base)
        return true
    }

    func revertToOriginal() {
        do {
            try TranscriptEditStore.revert(workDir: workDir, base: base)
        } catch {
            message = "Not reverted — nothing was changed: \(error.localizedDescription)"
            return
        }
        isEditing = false
        loadTranscript()
        noteIsStale = true
        message = "Original transcript restored. Re-summarise to rewrite the note from it."
        didSave(base)
    }

    func resummariseNote() {
        guard !dirty, !busy else { return }
        busy = true
        message = "Re-summarising from the saved transcript…"
        let b = base
        Task { [weak self] in
            guard let self else { return }
            let outcome = await self.resummarise(b)
            self.busy = false
            if outcome.ok { self.noteIsStale = false }
            self.message = outcome.message
        }
    }

    // MARK: Playback

    private func loadPlayer() {
        loadGeneration += 1
        let gen = loadGeneration
        playbackProblem = nil; durationSeconds = 0; currentSeconds = 0
        guard transcript != nil else {
            playbackProblem = "Playback is off: no timestamps were saved for this recording."
            return
        }
        let b = base, find = findSource
        Task { [weak self] in
            let url = await Task.detached(priority: .userInitiated) { find(b) }.value
            guard let self, gen == self.loadGeneration else { return }
            guard let url else {
                self.playbackProblem = "Playback is off: the recording file was not found (moved, deleted or not in the recordings folder)."
                return
            }
            let asset = AVURLAsset(url: url)
            let playable = (try? await asset.load(.isPlayable)) ?? false
            let duration = (try? await asset.load(.duration)).map { $0.seconds } ?? 0
            guard gen == self.loadGeneration else { return }
            guard playable else {
                self.playbackProblem = "Playback is off: \(url.lastPathComponent) cannot be played."
                return
            }
            self.durationSeconds = duration.isFinite ? Int(duration) : 0
            self.attachPlayer(AVPlayerItem(asset: asset))
        }
    }

    private func attachPlayer(_ item: AVPlayerItem) {
        let p = AVPlayer(playerItem: item)
        player = p
        // ~10 Hz drives the highlight; it only touches the previous and current token.
        timeObserver = p.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.isPlaying = false } }
        objectWillChange.send()
    }

    private func tick(_ seconds: Double) {
        guard seconds.isFinite else { return }
        let whole = Int(seconds)
        if whole != currentSeconds { currentSeconds = whole }   // 1 Hz for the label
        guard !isEditing, let l = layout else { return }
        let idx = l.tokenIndex(at: seconds)
        if idx != highlight { highlight = idx }
    }

    func togglePlay() {
        guard let p = player else { return }
        if isPlaying { p.pause(); isPlaying = false }
        else { p.rate = rate; isPlaying = true }
    }

    /// Click-to-seek: jump to the word at UTF-16 `index` and keep playing.
    func seek(characterIndex index: Int) {
        guard let l = layout, let t = l.time(forCharacterIndex: index) else { return }
        seek(to: t, play: true)
    }

    func skip(_ delta: Double) {
        guard let p = player else { return }
        seek(to: max(0, p.currentTime().seconds + delta), play: isPlaying)
    }

    private func seek(to seconds: Double, play: Bool) {
        guard let p = player else { return }
        p.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        if !isEditing, let l = layout { highlight = l.tokenIndex(at: seconds) }
        currentSeconds = Int(seconds)
        if play { p.rate = rate; isPlaying = true }
    }

    private func teardownPlayer() {
        if let o = timeObserver { player?.removeTimeObserver(o) }
        if let e = endObserver { NotificationCenter.default.removeObserver(e) }
        timeObserver = nil; endObserver = nil
        player?.pause(); player = nil
        isPlaying = false; highlight = nil
        loadGeneration += 1
    }

    /// Window closing.
    func shutdown() { teardownPlayer() }
}
