import SwiftUI
import DistavoCore

/// Recording pane, "Meeting detection" section (Vikunja #2945): offer to record
/// when a listed call app is running and the microphone is in use. Off by default.
/// Shown only where the built-in recorder exists (macOS 14.4+).
struct MeetingDetectionSection: View {
    @ObservedObject var model: SettingsModel
    @State private var newApp = ""

    var body: some View {
        Section("Meeting detection") {
            Toggle("Offer to record when a call starts", isOn: $model.draft.meetingDetection.enabled)
                .withHelp("While this is on, Distavo checks about once a second whether one of the apps below is running and the microphone is in use by any app, and then shows a notification with Record and Not now buttons. Nothing is recorded until you click Record. It reads only app names and a yes/no microphone flag - it never listens to or opens the microphone. Google Meet in a browser can only be detected by adding your browser to the list, and then any other microphone use in that browser (a voice message, a dictation site) also prompts. The microphone flag is system-wide, so a listed app that is merely open plus dictation elsewhere can look like a call.")
            SettingCaption("Nothing is recorded until you click Record.")
            if model.draft.meetingDetection.enabled {
                Stepper("Not now snoozes that app for \(model.draft.meetingDetection.snoozeMinutes) min",
                        value: $model.draft.meetingDetection.snoozeMinutes,
                        in: MeetingDetectionConfig.snoozeMinutesRange, step: 5)
                ForEach(model.draft.meetingDetection.apps, id: \.self) { id in
                    HStack {
                        Text(MeetingDetectionConfig.displayName(forBundleID: id))
                        if MeetingDetectionConfig.knownNames[id] != nil {
                            Text(id).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            model.draft.meetingDetection.apps.removeAll { $0 == id }
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help("Stop watching \(id)")
                    }
                }
                HStack {
                    TextField("Add an app by bundle id, e.g. com.google.Chrome", text: $newApp)
                        .onSubmit(addApp)
                    Button("Add", action: addApp)
                        .disabled(newApp.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Reset list") { model.draft.meetingDetection.apps = MeetingDetectionConfig.defaultApps }
                }
                SettingCaption("Browsers are not watched by default; add one only if you take calls in it.")
            }
        }
    }

    private func addApp() {
        let id = newApp.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, !model.draft.meetingDetection.apps.contains(id) else { newApp = ""; return }
        model.draft.meetingDetection.apps.append(id)
        newApp = ""
    }
}
