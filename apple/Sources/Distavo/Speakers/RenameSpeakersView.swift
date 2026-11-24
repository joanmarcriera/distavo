import SwiftUI
import AppKit
import DistavoCore

// "Rename Speakers…" (Vikunja #2944, phase 1): a small window listing the
// speakers detected in a note, each with its turn count, a sample line and an
// editable name. Apply rewrites the note, the cached transcript and the timed
// sidecar atomically (`SpeakerRename.apply`, DistavoCore); this file is the
// thin UI. Since 1.18 it is a sheet on the Notes window, opened for the selected
// note (it has no note chooser of its own).

/// The note the sheet is about.
struct RenamableNote: Identifiable, Equatable {
    let base: String
    let title: String
    var id: String { base }
}

struct RenameSpeakersView: View {
    let note: RenamableNote
    /// Speakers of a note (reads the files; nil/empty = none found).
    let detect: (String) -> [DetectedSpeaker]
    /// current name -> original label for speakers renamed earlier (empty = nothing to reset).
    let resetMapping: (String) -> [String: String]
    /// Dry run: the note lines the pending names would change.
    let preview: (String, [String: String]) -> [SpeakerRename.NoteChange]
    /// `.pre-merge-*` copies kept by earlier merges of this note.
    let mergeCopies: (String) -> [URL]
    let onReset: (String) -> Void
    /// Called with the note and current-label -> new-name; the window closes right after.
    let onApply: (String, [String: String]) -> Void
    let onCancel: () -> Void
    /// Voice profiles (#2944): whether to offer "Remember this voice" (Settings > Transcription), and what to
    /// call INSTEAD of `onApply` when a voice is ticked: the note, the mapping (may be empty) and the final
    /// names of the ticked speakers. One call, so the rename is done before the voices are read.
    var voiceProfilesOn: Bool = false
    var onApplyAndRemember: (String, [String: String], [String]) -> Void = { _, _, _ in }
    @State private var remember: Set<String> = []
    /// Names this note got from voice recognition and the owner has not confirmed (`SpeakerNames.byVoice`),
    /// and what to call with the ones ticked "this is right".
    var voiceGuesses: (String) -> [String] = { _ in [] }
    var onConfirm: (String, [String]) -> Void = { _, _ in }
    @State private var guessed: Set<String> = []
    @State private var confirmed: Set<String> = []
    /// Ticked guesses whose name the owner left as it is (a changed name is theirs anyway).
    private var confirmedNames: [String] {
        speakers.map(\.label).filter { confirmed.contains($0) && guessed.contains($0) && changes[$0] == nil }
    }

    private var selectedBase: String { note.base }
    @State private var speakers: [DetectedSpeaker] = []
    @State private var names: [String: String] = [:]

    init(note: RenamableNote, detect: @escaping (String) -> [DetectedSpeaker],
         resetMapping: @escaping (String) -> [String: String],
         preview: @escaping (String, [String: String]) -> [SpeakerRename.NoteChange],
         mergeCopies: @escaping (String) -> [URL], onReset: @escaping (String) -> Void,
         onApply: @escaping (String, [String: String]) -> Void, onCancel: @escaping () -> Void,
         voiceProfilesOn: Bool = false,
         onApplyAndRemember: @escaping (String, [String: String], [String]) -> Void = { _, _, _ in },
         voiceGuesses: @escaping (String) -> [String] = { _ in [] },
         onConfirm: @escaping (String, [String]) -> Void = { _, _ in }) {
        self.voiceGuesses = voiceGuesses; self.onConfirm = onConfirm
        self.voiceProfilesOn = voiceProfilesOn; self.onApplyAndRemember = onApplyAndRemember
        self.note = note; self.detect = detect; self.resetMapping = resetMapping
        self.preview = preview; self.mergeCopies = mergeCopies; self.onReset = onReset
        self.onApply = onApply; self.onCancel = onCancel
    }

    /// Non-empty edits that differ from the label.
    private var changes: [String: String] {
        var out: [String: String] = [:]
        for s in speakers {
            let new = (names[s.label] ?? s.label).trimmingCharacters(in: .whitespacesAndNewlines)
            if !new.isEmpty, new != s.label { out[s.label] = new }
        }
        return out
    }
    /// Final names of the ticked speakers that carry a real name (never a diariser label).
    private var rememberNames: [String] {
        guard voiceProfilesOn else { return [] }
        return speakers.filter { remember.contains($0.label) }
            .map { (names[$0.label] ?? $0.label).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter(Self.isRealName)
    }
    private static func isRealName(_ s: String) -> Bool {
        !s.isEmpty && s.range(of: #"^SPEAKER_\d{1,3}$"#, options: .regularExpression) == nil
    }
    private var hasEmptyName: Bool {
        speakers.contains { (names[$0.label] ?? $0.label).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    private var invalidName: String? {
        names.values.first { $0.contains("[") || $0.contains("]") || $0.contains("\n") || $0.count > SpeakerRename.maxNameLength }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Rename speakers in “\(note.title)”").font(.headline).lineLimit(2)
                Text("\(note.base).md").font(.caption.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Text("Type a name for each speaker. Every mention is replaced in the note, the saved transcript and the timestamps file, so exports and Regenerate use the new names. The previous note is kept as “….prev-<date>.md”. Mentions inside sentences are not changed. Giving two speakers the same name merges them, which cannot be undone from the app.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            Group {
                if speakers.isEmpty {
                    Text("No speakers found in this note.").foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(speakers, id: \.label) { s in
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(s.label).font(.system(.body, design: .monospaced))
                                        Text("\(s.turns) turn\(s.turns == 1 ? "" : "s")")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    if !s.sample.isEmpty {
                                        Text("“\(s.sample)”").font(.caption).foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    TextField("Name", text: Binding(
                                        get: { names[s.label] ?? s.label },
                                        set: { names[s.label] = $0 }))
                                    if guessed.contains(s.label), (names[s.label] ?? s.label) == s.label {
                                        Toggle("Named by voice recognition. Tick if this is right", isOn: Binding(
                                            get: { confirmed.contains(s.label) },
                                            set: { if $0 { confirmed.insert(s.label) } else { confirmed.remove(s.label) } }))
                                            .font(.caption)
                                            .help("Until you confirm it, a name Distavo recognised by voice is a guess: it is shown as “recognised by voice” on that person's page and never creates a page.")
                                    }
                                    if voiceProfilesOn {
                                        Toggle("Recognise them automatically next time", isOn: Binding(
                                            get: { remember.contains(s.label) },
                                            set: { if $0 { remember.insert(s.label) } else { remember.remove(s.label) } }))
                                            .font(.caption)
                                            .disabled(!Self.isRealName((names[s.label] ?? s.label).trimmingCharacters(in: .whitespacesAndNewlines)))
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(maxHeight: 320)
                }
                if !changes.isEmpty {
                    let ch = preview(selectedBase, changes)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ch.isEmpty ? "No line of the note will change (the transcript and timestamps will)."
                                        : "\(ch.count) line\(ch.count == 1 ? "" : "s") of the note will change:")
                            .font(.caption).bold()
                        ForEach(ch.prefix(5), id: \.line) { c in
                            Text("\(c.line): \(c.after.trimmingCharacters(in: .whitespaces))")
                                .font(.caption.monospaced()).lineLimit(1).truncationMode(.tail)
                        }
                        if ch.count > 5 { Text("…and \(ch.count - 5) more").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                let copies = mergeCopies(selectedBase)
                if resetMapping(selectedBase).isEmpty, !copies.isEmpty {
                    HStack {
                        Text("Merged speakers cannot be separated again. Copies from before the merge are in the work folder.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button("Show copies") { NSWorkspace.shared.activateFileViewerSelecting(copies) }
                    }
                }
                if voiceProfilesOn {
                    Text("“Recognise them automatically next time” keeps a voiceprint of that person on this Mac, so Distavo puts their name in future notes without asking. Tick it for people you meet again and who agreed; leave it off for a one-off voice. Voiceprints can be deleted in Settings > Transcription.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if hasEmptyName {
                    Text("A name cannot be empty.").font(.caption).foregroundStyle(.orange)
                } else if invalidName != nil {
                    Text("Names cannot contain square brackets or line breaks (max \(SpeakerRename.maxNameLength) characters).")
                        .font(.caption).foregroundStyle(.orange)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                if !resetMapping(selectedBase).isEmpty {
                    Button("Reset to original labels") { onReset(selectedBase) }
                }
                Button("Apply") { confirmAndApply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled((changes.isEmpty && rememberNames.isEmpty && confirmedNames.isEmpty) || hasEmptyName || invalidName != nil)
            }
        }
        .padding(16)
        .frame(width: 520)
        .onAppear { reload() }
    }

    /// A merge loses information, so it is confirmed first.
    private func confirmAndApply() {
        let merges = SpeakerRename.merges((try? SpeakerRename.normalised(changes)) ?? changes,
                                          present: speakers.map(\.label))
        if !merges.isEmpty {
            let alert = NSAlert()
            alert.messageText = merges.map { "Merge \($0.from.joined(separator: ", ")) into \($0.into)?" }
                .joined(separator: "\n")
            alert.informativeText = "This cannot be undone from the app. A copy of the transcript and timestamps is kept in the work folder (“….pre-merge-…”)."
            alert.addButton(withTitle: "Merge")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let voices = rememberNames
        let sure = confirmedNames
        if !sure.isEmpty { onConfirm(selectedBase, sure) }
        // Only a confirmation: there is nothing to rename (and no "nothing to rename" message to show).
        if changes.isEmpty, voices.isEmpty { onCancel(); return }
        if voices.isEmpty { onApply(selectedBase, changes) } else { onApplyAndRemember(selectedBase, changes, voices) }
    }

    private func reload() {
        speakers = selectedBase.isEmpty ? [] : detect(selectedBase)
        names = [:]
        remember = []
        guessed = Set(selectedBase.isEmpty ? [] : voiceGuesses(selectedBase))
        confirmed = []
    }
}
