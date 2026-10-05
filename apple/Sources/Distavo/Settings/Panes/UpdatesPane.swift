import SwiftUI

// The whole file is Direct-only: Sparkle is linked into the Direct target alone,
// and the Updates pane is only listed there (`SettingsModel.visiblePanes`).
#if EDITION_DIRECT
/// Updates (Direct edition only): Sparkle auto-check toggle and manual check.
struct UpdatesPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Section("Updates") {
            Toggle("Automatically check for updates", isOn: $model.autoUpdates)
                .onChange(of: model.autoUpdates) { _, on in
                    model.controller.updater?.automaticallyChecksForUpdates = on
                }
            Button("Check for updates now…") { model.controller.updater?.checkForUpdates() }
        }
    }
}
#endif
