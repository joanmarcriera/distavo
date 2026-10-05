import Foundation

/// The panes of the Settings window and the pure rules about them (Vikunja #2957):
/// which panes exist for an edition, how the sidebar search filters them, and how a
/// remembered selection is resolved. UI-free so it is unit-tested headlessly; the
/// SwiftUI shell (`apple/Sources/Distavo/Settings/`) only renders what this decides.
///
/// Adding a pane: add a case here (title, symbol, keywords), add its view under
/// `Settings/Panes/`, and add one `case` to `SettingsView.detail`.
public enum SettingsPane: String, CaseIterable, Identifiable, Sendable {
    case general, recording, transcription, notes, summaries, connections, updates, about

    public var id: String { rawValue }

    /// Sidebar title, in sidebar order (declaration order of the cases).
    public var title: String {
        switch self {
        case .general: return "General"
        case .recording: return "Recording"
        case .transcription: return "Transcription"
        case .notes: return "Notes"
        case .summaries: return "Summaries"
        case .connections: return "Connections"
        case .updates: return "Updates"
        case .about: return "About"
        }
    }

    /// SF Symbol for the sidebar row.
    public var symbolName: String {
        switch self {
        case .general: return "gearshape"
        case .recording: return "record.circle"
        case .transcription: return "waveform"
        case .notes: return "note.text"
        case .summaries: return "text.append"
        case .connections: return "network"
        case .updates: return "arrow.triangle.2.circlepath"
        case .about: return "info.circle"
        }
    }

    /// Words (besides the title) that make the sidebar search show this pane. Keep
    /// these in step with the controls the pane holds — it is how a setting is found.
    public var keywords: [String] {
        switch self {
        case .general:
            return ["folder", "watch", "interval", "notes folder", "work folder", "login", "startup", "getting started"]
        case .recording:
            return ["record", "silence", "stop", "short", "shrink", "compact", "speakers", "when done",
                    "open note", "open transcript", "retry", "bigger", "meeting detection", "detect", "call",
                    "zoom", "teams", "facetime", "snooze",
                    "key moment", "bookmark", "marker", "hotkey", "shortcut", "clip", "export clip"]
        case .transcription:
            return ["engine", "model", "whisper", "whisperx", "parakeet", "language", "spoken", "catalan",
                    "language pack", "speakers", "diarize", "download", "benchmark", "disk",
                    "vocabulary", "glossary", "dictionary", "replace", "names", "jargon", "spelling"]
        case .notes:
            return ["prompt", "facts first", "classic", "write notes in", "note language", "owner",
                    "speaker label", "your name", "english", "language", "original language",
                    "translate", "french", "german", "always write",
                    "template", "meeting type", "stand-up", "standup", "1:1", "interview", "sales call",
                    "lecture", "custom template", "folder template", "headings", "sections",
                    "action items", "tasks", "decisions", "reminders", "checkbox", "todo",
                    "calendar", "event", "attendees", "rename", "meeting title",
                    "obsidian", "frontmatter", "yaml", "tags", "title", "vault", "tracked terms", "keywords", "properties"]
        case .summaries:
            return ["ollama", "backend", "server", "local", "apple intelligence", "on-device", "gemma",
                    "summary model", "bigger model", "fallback"]
        case .connections:
            return ["test", "connection", "permissions", "local network", "reachable", "status"]
        case .updates:
            return ["update", "sparkle", "automatic", "check"]
        case .about:
            return ["version", "privacy", "licence", "license", "edition"]
        }
    }

    /// Panes shown for an edition. `hasUpdates` is true only where the Sparkle updater
    /// is compiled in (Direct); a pane that would be empty is never listed.
    public static func visible(hasUpdates: Bool) -> [SettingsPane] {
        allCases.filter { $0 != .updates || hasUpdates }
    }

    /// Case- and diacritic-insensitive match on title or any keyword. Every
    /// whitespace-separated term of `query` must match (so "note owner" finds Notes).
    /// A blank query keeps everything.
    public func matches(_ query: String) -> Bool {
        let terms = Self.fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
        if terms.isEmpty { return true }
        let haystack = ([title] + keywords).map(Self.fold)
        return terms.allSatisfy { term in haystack.contains { $0.contains(term) } }
    }

    /// `panes` filtered by `query`, order preserved.
    public static func filter(_ panes: [SettingsPane], query: String) -> [SettingsPane] {
        panes.filter { $0.matches(query) }
    }

    /// Resolve a remembered raw value (UserDefaults) to a pane that is visible in this
    /// edition; unknown, stale or edition-hidden values fall back to the first pane.
    public static func resolve(stored: String?, among visible: [SettingsPane]) -> SettingsPane {
        if let stored, let pane = SettingsPane(rawValue: stored), visible.contains(pane) { return pane }
        return visible.first ?? .general
    }

    /// The pane to show while a filter is active: `current` if it still matches,
    /// otherwise the first match, or nil when nothing matches ("No matching settings").
    public static func effectiveSelection(current: SettingsPane, filtered: [SettingsPane]) -> SettingsPane? {
        filtered.contains(current) ? current : filtered.first
    }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
