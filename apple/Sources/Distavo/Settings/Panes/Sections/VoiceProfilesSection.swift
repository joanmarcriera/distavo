import SwiftUI
import AppKit
import DistavoCore

/// "Recognise remembered voices" (#2944 phase 2), rows inside Transcription > "Spoken language and speakers".
/// Logic: `VoiceProfileStore` / `VoiceRecognition` (DistavoCore), engine `VoiceEmbedder` (DistavoEmbedded).
/// This view edits `draft.transcribe.voiceProfiles` and lists / deletes the stored voices.
/// Not offered in the App Store edition until its privacy answers declare the voiceprint
/// (docs/voice-profiles-plan.md, "Edition gating").
struct VoiceProfilesSection: View {
    @ObservedObject var model: SettingsModel
    @State private var names: [String] = []
    @State private var confirmDeleteAll = false

    var body: some View {
        #if !EDITION_APPSTORE
        Toggle("Recognise remembered voices", isOn: $model.draft.transcribe.voiceProfiles)
            .withHelp("When you rename a speaker in the Notes window you can tick “Recognise them automatically next time”. Distavo then stores a voiceprint of that person on this Mac and names them in later notes when it hears the same voice. A voiceprint is biometric data about another person: remember a voice only when that person agreed. Nothing is stored until you tick the box, it never leaves this Mac, and you can delete it here. The first use downloads a small voice model (about 13 MB).")
        if model.draft.transcribe.voiceProfiles || !names.isEmpty {
            if names.isEmpty {
                SettingCaption("No voice remembered yet. Rename a speaker in the Notes window and tick “Recognise them automatically next time”.")
            } else {
                ForEach(names, id: \.self) { name in
                    HStack {
                        Text(name)
                        Spacer()
                        Button("Rename…") { rename(name) }
                            .help("Correct the name, or type the name of another remembered voice to make the two one person.")
                        Button("Delete") { delete(name) }
                    }
                }
                HStack {
                    Spacer()
                    Button("Delete All Voices…") { confirmDeleteAll = true }
                }
                .confirmationDialog("Delete all remembered voices?", isPresented: $confirmDeleteAll) {
                    Button("Delete All", role: .destructive) { deleteAll() }
                } message: {
                    Text("Notes keep the names they have. Distavo will no longer recognise these voices.")
                }
            }
        }
        Color.clear.frame(height: 0).onAppear { reload() }
        #endif
    }

    private func store() -> VoiceProfileStore {
        VoiceProfileStore.load(supportDir: NameGlossary.defaultSupportDir, model: VoiceProfileStore.builtInModel)
    }

    private func reload() { names = store().names.sorted { $0.lowercased() < $1.lowercased() } }

    private func rename(_ name: String) {
        let alert = NSAlert()
        alert.messageText = "Rename the voice of \(name)"
        alert.informativeText = "Type the right name. If another remembered voice already has that name, the two become one person. Your notes keep the names they have."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = name
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        VoiceProfileStore.fileLock.lock(); defer { VoiceProfileStore.fileLock.unlock() }
        var s = store()
        guard s.rename(name: name, to: field.stringValue) != .unchanged else { return }
        try? s.save(supportDir: NameGlossary.defaultSupportDir)
        reload()
    }

    private func delete(_ name: String) {
        VoiceProfileStore.fileLock.lock(); defer { VoiceProfileStore.fileLock.unlock() }
        var s = store()
        // Nothing found = nothing to save (never write over a voice file this build cannot read).
        guard s.delete(name: name) else { return }
        try? s.save(supportDir: NameGlossary.defaultSupportDir)
        reload()
    }

    private func deleteAll() {
        VoiceProfileStore.fileLock.lock(); defer { VoiceProfileStore.fileLock.unlock() }
        var s = store()
        s.deleteAll()
        try? s.save(supportDir: NameGlossary.defaultSupportDir)
        reload()
    }
}
