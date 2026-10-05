import SwiftUI
import DistavoCore

/// Recording: the built-in recorder's behaviour, short-recording handling,
/// compaction, and what to do automatically when a recording finishes.
struct RecordingPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        if MeetingCaptureController.isSupported {
            Section("Meeting recorder") {
                Toggle("Ask who was in the meeting when a recording stops",
                       isOn: $model.draft.askSpeakersOnStop)
                    .withHelp("After you stop the built-in recorder, Distavo asks how many people spoke, your role and who the others were, and hands that to the summariser so the notes name the speakers and the follow-up email is written from your side. Skip the question any time.")
                // Silence handling (Vikunja #2665). Both are off by default:
                // an unwanted stop loses audio for good.
                HStack {
                    Toggle("Suggest stopping after silence", isOn: $model.draft.suggestStopOnSilence)
                    Stepper("\(model.draft.suggestStopSilenceMinutes) min",
                            value: $model.draft.suggestStopSilenceMinutes, in: Config.silenceMinutesRange)
                        .disabled(!model.draft.suggestStopOnSilence)
                    HelpButton(text: "When nothing has been heard on the microphone or the meeting audio for this long, Distavo shows a notification (and a menu item) offering to stop the recording or keep going. It never stops by itself.")
                }
                HStack {
                    Toggle("Stop recording automatically after silence", isOn: $model.draft.autoStopOnSilence)
                    Stepper("\(model.draft.autoStopSilenceMinutes) min",
                            value: $model.draft.autoStopSilenceMinutes, in: Config.silenceMinutesRange)
                        .disabled(!model.draft.autoStopOnSilence)
                    HelpButton(text: "Ends the recording, saves it and processes it as usual after this many minutes of silence on both the microphone and the meeting audio. It only applies once something has been heard, so waiting in a silent lobby never stops it. A very quiet meeting or a long pause can trigger it; choose Keep recording on the suggestion to prevent that.")
                }
                if model.draft.suggestStopOnSilence, model.draft.autoStopOnSilence,
                   model.draft.autoStopSilenceMinutes <= model.draft.suggestStopSilenceMinutes {
                    SettingCaption("This stops the recording before the suggestion would appear.")
                }
            }
        }

        if MeetingCaptureController.isSupported { MeetingDetectionSection(model: model) }
        if MeetingCaptureController.isSupported { KeyMomentsSection(model: model) }   // #2950

        Section("Recordings") {
            Stepper("Ignore recordings shorter than \(model.draft.minRecordingSeconds) s",
                    value: $model.draft.minRecordingSeconds, in: 0...120, step: 5)
                .withHelp("A recording under this length is set aside instead of producing an empty note — the menu offers to delete it. Set to 0 to transcribe everything.")
            Toggle("Shrink recordings once the note is written",
                   isOn: $model.draft.compactRecordingsAfterNote)
                .withHelp("The built-in recorder keeps a 48 kHz stereo take (about 1.4 GB per hour). Once the note is written, Distavo replaces WAV recordings with the 16 kHz mono copy the transcriber used — about 20x smaller. Other formats are left alone.")
        }

        Section {
            Toggle("Open the note", isOn: model.whenDoneBinding(.openNote))
            Toggle("Open the transcript", isOn: model.whenDoneBinding(.openTranscript))
            Toggle("Re-transcribe with a bigger model", isOn: model.whenDoneBinding(.retryTranscribeBigger))
                .disabled(!model.canRetryTranscribeBigger)
            if !model.canRetryTranscribeBigger {
                SettingCaption("Needs a specific built-in model chosen in Transcription (not Automatic) that has a bigger option for its language.")
            }
            Toggle("Re-summarise with a bigger model", isOn: model.whenDoneBinding(.retrySummariseBigger))
                .disabled(!model.canRetrySummariseBigger)
            if !model.canRetrySummariseBigger {
                SettingCaption("Set a “Bigger model” in Summaries to enable this.")
            }
        } header: {
            HStack {
                Text("When a recording finishes")
                HelpButton(text: "Run any of these automatically as soon as a recording is processed, instead of waiting to act from the menu. Tick as many as you like — the note/transcript actions just open a file; the re-run actions queue another pass in the background and save it alongside the original as its own note.")
            }
        }
    }
}
