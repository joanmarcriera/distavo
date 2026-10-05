import SwiftUI
import DistavoCore

// HOW TO ADD A SETTING (Vikunja #2957)
// ------------------------------------
// The window is a sidebar (`SettingsPane`, in DistavoCore) + one SwiftUI view per pane
// in `Settings/Panes/<Name>Pane.swift`. Every pane is a small `View` that takes the shared
// `SettingsModel` and returns one or more `Section`s. To add:
//
//  * a ROW to an existing pane — open that pane's file and add a control bound to the
//    draft config, e.g. `Toggle("My option", isOn: $model.draft.myNewKey)`. Add a short
//    `SettingCaption("…")` if it needs explaining and put the long text in `.withHelp("…")`.
//  * a SECTION — add another `Section("Title") { … }` in the same pane file.
//  * a PANE — add a case to `SettingsPane` (title, symbol, keywords) in DistavoCore, create
//    `Panes/<Name>Pane.swift`, and add one `case` to `detail` below. Run `xcodegen generate`.
//  * edition/backend-dependent visibility — add a computed property to `SettingsModel`
//    (see `usesBuiltInTranscription`) instead of an inline `#if`/`if` in the pane. Anything
//    edition-only must stay behind `#if EDITION_*` (see UpdatesPane); a pane that would be
//    empty in an edition must not be listed there.
//  * search — add the new control's words to that pane's `keywords` in `SettingsPane`.
//
// Saving is explicit: edits go to `model.draft`; the bottom bar's Save applies them and
// Revert discards them. Never write `controller.config` directly from a pane. New config
// keys follow the usual rule (decode to off/legacy for a config that predates them).

/// Native settings window — a sidebar of panes with a detail form, replacing the old
/// single long scroll. Edits a draft Config and applies it to the controller on Save.
struct SettingsView: View {
    @StateObject private var model: SettingsModel
    /// Remembered last pane. UserDefaults, deliberately NOT a Config key (it is window
    /// chrome, not behaviour, and must never reach watcher-config.json).
    @AppStorage("settings.selectedPane") private var storedPane = SettingsPane.general.rawValue
    @State private var query = ""

    init(controller: WatcherController) {
        _model = StateObject(wrappedValue: SettingsModel(controller: controller))
    }

    private var filteredPanes: [SettingsPane] {
        SettingsPane.filter(model.visiblePanes, query: query)
    }

    /// Pane shown now: the remembered one, or the first match if the filter hides it;
    /// nil when nothing matches.
    private var current: SettingsPane? {
        SettingsPane.effectiveSelection(
            current: SettingsPane.resolve(stored: storedPane, among: model.visiblePanes),
            filtered: filteredPanes)
    }

    private var selection: Binding<SettingsPane?> {
        Binding(
            get: { current },
            set: { if let pane = $0 { storedPane = pane.rawValue } })
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 160, ideal: 190, max: 260)
        } detail: {
            detailForm
        }
        .frame(minWidth: 700, idealWidth: 780, minHeight: 460, idealHeight: 600)
        .sheet(isPresented: $model.showingPermissions) { PermissionsView(config: model.draft) }
        .onAppear { model.windowAppeared() }
        .onDisappear { model.saveIfNeededOnClose() }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            TextField("Filter settings", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding([.horizontal, .top], 10)
                .padding(.bottom, 6)
                .accessibilityLabel("Filter settings panes")
            List(filteredPanes, selection: selection) { pane in
                Label(pane.title, systemImage: pane.symbolName)
                    .tag(pane)
            }
        }
    }

    // MARK: Detail

    private var detailForm: some View {
        Group {
            if let current {
                Form { detail(for: current) }
                    .formStyle(.grouped)
                    .navigationTitle(current.title)
            } else {
                Text("No matching settings")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .safeAreaInset(edge: .bottom) { bottomBar }
    }

    /// One case per pane. Panes are plain Views taking the shared model.
    @ViewBuilder private func detail(for pane: SettingsPane) -> some View {
        switch pane {
        case .general: GeneralPane(model: model)
        case .recording: RecordingPane(model: model)
        case .transcription: TranscriptionPane(model: model)
        case .notes: NotesPane(model: model)
        case .summaries: SummariesPane(model: model)
        case .connections: ConnectionsPane(model: model)
        case .updates:
            #if EDITION_DIRECT
            UpdatesPane(model: model)
            #else
            EmptyView()   // never selectable: SettingsModel.visiblePanes omits it
            #endif
        case .about: AboutPane(model: model)
        }
    }

    // MARK: Save bar

    /// Pinned bottom bar so Save is always visible without scrolling.
    /// Save behaviour is explicit (not live-apply): edits stay in the draft until Save.
    /// Closing the window with pending edits still saves them, and the bar says so.
    private var bottomBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                if model.hasUnsavedChanges {
                    Text("Unsaved changes — saved when you close this window")
                        .font(.callout).foregroundStyle(.secondary)
                } else if model.saved {
                    Text("Saved — applied immediately.").foregroundStyle(.green).font(.callout)
                }
                Spacer()
                Button("Revert") { model.revert() }
                    .disabled(!model.hasUnsavedChanges)
                Button("Save") { model.save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.hasUnsavedChanges)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
        .background(.regularMaterial)
    }
}
