import SwiftUI
import DistavoCore
import DistavoEmbedded

/// Transcription: engine (built-in vs WhisperX server), model, the SPOKEN language,
/// speakers/diarisation, language packs, benchmark and model downloads.
/// The language the NOTES are written in is a different setting — see NotesPane.
struct TranscriptionPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Section("Engine") {
            if model.embeddedSupported {
                Picker("Engine", selection: $model.draft.transcribe.backend) {
                    Text("Built-in (this Mac)").tag("embedded")
                    Text("WhisperX server").tag("server")
                }
                .withHelp("‘Built-in’ transcribes on this Mac with Whisper — no server or install needed; the model downloads once. ‘WhisperX server’ sends audio to a WhisperX URL you run yourself.")
            } else {
                SettingCaption("Built-in transcription needs an Apple Silicon Mac — this Mac uses a WhisperX server.")
            }

            if model.usesBuiltInTranscription {
                builtInEngineRows
            } else {
                HStack {
                    TextField("WhisperX URL", text: $model.draft.transcribe.whisperxURL)
                    ServerHelpButton(kind: .whisperx)
                }
                Picker("Model", selection: $model.draft.transcribe.model) {
                    ForEach(SettingsModel.whisperXModels, id: \.self) { Text($0).tag($0) }
                }
            }
        }

        Section("Spoken language and speakers") {
            languagePicker
            SettingCaption("The language people speak in your recordings (this is not the language of the finished note). To write notes in English, the meeting's own language, or a fixed language, see Notes › Write notes in.")
            if let detected = model.controller.lastDetectedLanguages {
                SettingCaption("Last recording: detected \(detected).")
            }
            Stepper("Number of speakers: \(model.draft.transcribe.numSpeakers)",
                    value: $model.draft.transcribe.numSpeakers, in: 1...10)
                .withHelp("Roughly how many people are speaking. Helps separate and label speakers.")
            Toggle("Diarize (separate speakers)", isOn: $model.draft.transcribe.diarize)
                .withHelp("Label who said what (SPEAKER_00, SPEAKER_01…). Turn off for a single-speaker recording.")
        }

        if model.usesBuiltInTranscription {
            Section("Models") {
                modelManagementRows
            }
        }
    }

    // MARK: Built-in engine rows

    @ViewBuilder private var builtInEngineRows: some View {
        // `.disabled(...)` on a Picker's Text does not disable the menu
        // item on macOS, so unselectable entries (this Mac's memory is
        // below the model's floor) are filtered out of the list instead
        // and named in a caption below rather than shown as a dead row.
        // `modelChoices` still surfaces the current value even when it's
        // one of those unselectable/unknown ids, so the Picker's selection
        // always matches a real tag.
        Picker("Model", selection: $model.draft.transcribe.embeddedModel) {
            Text("Automatic (recommended)").tag(EmbeddedModelCatalog.automaticID)
            Divider()
            ForEach(model.modelChoices) { m in
                Text(model.selectableIDs.contains(m.id) ? "\(m.displayName) — \(m.downloadLabel)" : m.displayName)
                    .tag(m.id)
            }
        }
        if EmbeddedModelCatalog.isAutomatic(model.draft.transcribe.embeddedModel) {
            SettingCaption("Distavo picks the engine for the language it hears and downloads what it needs once.")
                .withHelp("Distavo listens to three short windows, picks the engine for the language it hears — Catalan, Spanish and their mix on the Barcelona models, 25 other European languages on the fast Parakeet engine, everything else on Whisper (or a language pack you switch on below) — and downloads what it needs once.")
            if model.bscSelectable {
                Picker("Preferred Catalan model", selection: $model.draft.transcribe.preferredCatalanModel) {
                    Text("Català · Castellà · Galego · Euskara (Languages of Spain)").tag("bsc-los")
                    Text("Català only (3,370 hours)").tag("bsc-ca-3370h")
                }
            }
            languagePacksRows
        } else {
            let m = EmbeddedModelCatalog.model(id: model.draft.transcribe.embeddedModel)
            SettingCaption("\(m.detail) \(m.ramLabel).")
        }
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
            let runnable = pack.modelIDs.allSatisfy { model.selectableIDs.contains($0) }
            let floor = pack.modelIDs.map { EmbeddedModelCatalog.model(id: $0).minimumMemoryGB }.max() ?? 0
            Toggle(isOn: model.packBinding(pack.id)) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(pack.displayName) — \(pack.languageLabel) · \(pack.downloadMB) MB")
                    Text(runnable ? pack.credit : "\(pack.credit) · needs \(floor) GB of memory")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(!runnable)
        }
    }

    /// Benchmark, "Download now" and the on-disk model store.
    @ViewBuilder private var modelManagementRows: some View {
        BenchmarkButton(controller: model.controller)
        let unselectable = model.unselectableModels
        if !unselectable.isEmpty {
            SettingCaption("Not offered on this Mac (needs more memory): \(unselectable.map(\.displayName).joined(separator: ", ")).")
        }
        ModelDownloadButton(controller: model.controller, model: model)
        HStack {
            if let usage = model.modelsOnDisk {
                Text("Models on disk: \(usage)").font(.callout)
                Button("Remove downloaded models") {
                    Task { try? await ModelCoordinator.shared.removeAllModels(); model.modelsOnDisk = nil }
                }
            } else {
                SettingCaption("No models downloaded yet. They are kept in Application Support/Distavo/models.")
                    .withHelp("Distavo keeps every model it downloads in Application Support/Distavo/models; removing that folder removes all of them (macOS keeps its own small Core ML caches separately).")
            }
        }
    }

    // MARK: Spoken-language picker

    private var languagePicker: some View {
        Picker("Spoken language", selection: $model.draft.transcribe.language) {
            // C1: this row drives EngineRouter's per-meeting engine
            // choice (spec §5.2) — a choice that only exists on the
            // built-in engine. WhisperXClient maps "auto" to "" rather
            // than ever sending it to the server, so offering this row
            // to a WhisperX user would silently change what language
            // WhisperX is told (the server has no per-language engine
            // to route to). Show it only for the built-in engine.
            if model.usesBuiltInTranscription {
                Text("Automatic — pick the engine by language (recommended)").tag(EmbeddedModelCatalog.automaticID)
            } else if model.draft.transcribe.language == EmbeddedModelCatalog.automaticID {
                // A WhisperX user whose stored language is still "auto"
                // (set while on the built-in engine, or a fresh
                // install's default) — keep it selected and visible
                // instead of the Picker landing on nothing or silently
                // switching values, same as the unrecognised-code
                // synthetic row in `languageChoices`.
                Text("Automatic — built-in engine only; pick a language for WhisperX").tag(EmbeddedModelCatalog.automaticID)
            }
            // Distinct from the catalog's own "Auto-detect" (tag "", below):
            // the row above drives EngineRouter's per-meeting engine choice;
            // "Auto-detect" is Whisper's single-pass guess within whichever
            // model ends up chosen.
            ForEach(model.languageChoices) { lang in
                Text(lang.code.isEmpty ? "Auto-detect within the chosen model" : lang.englishName)
                    .tag(lang.code)
            }
        }
    }
}
