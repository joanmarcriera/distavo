import SwiftUI
import DistavoCore

/// Recording pane, "Start / stop shortcut" section (Vikunja #4001): an optional global shortcut that
/// starts the built-in recorder at once, with no dialog, and stops it on the second press. Who was
/// there, the role, language and so on are asked at the end as usual. Off by default.
/// Shown only where the built-in recorder exists (macOS 14.4+).
struct RecordHotkeySection: View {
    @ObservedObject var model: SettingsModel
    /// Set by the recorder when the last registration failed (combination taken).
    @AppStorage(RecordHotkeyModel.errorKey) private var registrationError = ""

    var body: some View {
        Section("Start / stop shortcut") {
            Toggle("Start and stop a recording with a keyboard shortcut",
                   isOn: $model.draft.recording.recordHotkeyEnabled)
                .withHelp("Works from any app. The first press starts recording at once with no questions and shows a \"Recording started\" notification; the next press stops it, and the usual end-of-recording sheet asks who was there. It needs no extra permission.")
            if model.draft.recording.recordHotkeyEnabled {
                HStack {
                    Text("Shortcut")
                    Spacer()
                    HotkeyRecorderField(spec: $model.draft.recording.recordHotkey)
                        .frame(width: 130, height: 24)
                    Button("Reset") { model.draft.recording.recordHotkey = .recordDefault }
                        .disabled(model.draft.recording.recordHotkey == .recordDefault)
                }
                SettingCaption("Click the box, then press the keys (include ⌃, ⌥ or ⌘). Applies when you close Settings.")
                if let problem = model.draft.recording.recordHotkeyProblem {
                    SettingCaption("⚠︎ \(problem)")
                } else if !registrationError.isEmpty {
                    SettingCaption("⚠︎ \(registrationError)")
                }
            }
        }
    }
}
