import AppKit
import SwiftUI
import DistavoCore

// State behind the "Ask Your Notes" window (Vikunja #2948). The chat lives only
// in this object's memory for the window's lifetime: nothing is written to disk
// and nothing is indexed. All answering logic is `AskNotes.ask` (DistavoCore);
// this is the thin UI model around it.

/// A note offered in the "This note" scope picker.
struct AskableNote: Identifiable, Equatable {
    let base: String
    let title: String
    var id: String { base }
}

/// One line of the chat.
struct AskMessage: Identifiable {
    enum Role { case user, assistant, notice }
    let id = UUID()
    let role: Role
    let text: String
    /// Sources the answer cites / everything the model saw (assistant only).
    var citations: [AskCitation] = []
    var consulted: [AskCitation] = []
    /// "Answered locally by …" / how the excerpts were chosen (assistant only).
    var backend: String?
    var method: String?
    /// Offer the "turn on the search index" button under this notice.
    var offersIndex = false
}

@MainActor
final class AskModel: ObservableObject {
    @Published private(set) var messages: [AskMessage] = []
    @Published var input = ""
    @Published var searchAllNotes = true
    @Published var selectedBase = ""
    @Published private(set) var notes: [AskableNote] = []
    @Published private(set) var busy = false
    /// Stop pressed; the task has not finished yet (a queued model call can only be
    /// abandoned once it reaches the front), so `busy` stays true until it does.
    @Published private(set) var stopping = false
    private var cleared = false

    /// Answers one question (supplied by `WatcherController`, which owns the config).
    private var provider: (String, AskScope, [AskTurn]) async -> AskOutcome = { _, _, _ in .cancelled }
    private var enableIndexAction: () async -> Void = {}
    private var task: Task<Void, Never>?

    func configure(notes: [AskableNote],
                   ask: @escaping (String, AskScope, [AskTurn]) async -> AskOutcome,
                   enableIndex: @escaping () async -> Void) {
        self.notes = notes
        provider = ask
        enableIndexAction = enableIndex
        if !notes.contains(where: { $0.base == selectedBase }) { selectedBase = notes.first?.base ?? "" }
    }

    /// Scope the chat to one note, or leave the scope alone for nil / an unknown note.
    func scope(to base: String?) {
        guard let base, notes.contains(where: { $0.base == base }) else { return }
        searchAllNotes = false
        selectedBase = base
    }

    /// Earlier answered question/answer pairs, for follow-ups (trimmed to the
    /// model's budget in `AskNotes`).
    private var history: [AskTurn] {
        var turns: [AskTurn] = [], pending: String?
        for m in messages {
            switch m.role {
            case .user: pending = m.text
            case .assistant:
                if let q = pending { turns.append(AskTurn(question: q, answer: m.text)); pending = nil }
            case .notice: pending = nil
            }
        }
        return turns
    }

    var canSend: Bool {
        !busy && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (searchAllNotes || !selectedBase.isEmpty)
    }

    func send() {
        let question = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        input = ""
        let scope: AskScope = searchAllNotes ? .allNotes : .note(base: selectedBase)
        let earlier = history
        messages.append(AskMessage(role: .user, text: question))
        busy = true
        let provider = self.provider
        task = Task {
            let outcome = await provider(question, scope, earlier)
            let wasStopped = stopping, wasCleared = cleared
            stopping = false; cleared = false
            if wasCleared { busy = false; return }
            if wasStopped || outcome == .cancelled {
                messages.append(AskMessage(role: .notice, text: "Stopped."))
            } else {
                apply(outcome)
            }
            busy = false
        }
    }

    func stop() {
        guard busy, !stopping else { return }
        stopping = true
        task?.cancel()
    }

    func clear() {
        messages = []
        if busy { cleared = true; task?.cancel() }
    }

    func enableIndex() {
        busy = true
        Task {
            await enableIndexAction()
            busy = false
            messages.append(AskMessage(role: .notice, text: "The search index is ready. Ask again."))
        }
    }

    func open(_ citation: AskCitation) { NSWorkspace.shared.open(citation.path) }

    private func apply(_ outcome: AskOutcome) {
        switch outcome {
        case .answered(let a):
            messages.append(AskMessage(role: .assistant, text: a.text, citations: a.citations,
                                       consulted: a.consulted, backend: a.backend, method: a.method))
        case .noMatches(let why): messages.append(AskMessage(role: .notice, text: why))
        case .needsIndex:
            messages.append(AskMessage(
                role: .notice,
                text: "Asking across all notes uses the search index, which has not been built yet. It is a local cache of your notes and transcripts on this Mac.",
                offersIndex: true))
        case .deferred(let why): messages.append(AskMessage(role: .notice, text: why))
        case .refused(let why): messages.append(AskMessage(role: .notice, text: why))
        case .failed(let why): messages.append(AskMessage(role: .notice, text: "Could not answer: \(why)"))
        case .cancelled: break
        }
    }
}
