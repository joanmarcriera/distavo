import SwiftUI
import DistavoCore

/// "Split Recording…" (D077): lists where the selected note's recording could be cut into two meetings and
/// does the split on confirm. The note was captured when the button was pressed (the Notes window never
/// moves the selection under a sheet). Logic: `RecordingSplit`, `RecordingSplitAction`; wiring:
/// `WatcherController+Split`.
struct SplitRecordingSheet: View {
    let entry: NoteEntry
    let controller: WatcherController
    let close: () -> Void

    @State private var choices: WatcherController.SplitChoices?
    @State private var problem: String?
    @State private var picked: Double?
    @State private var working = false
    @State private var result: String?

    private struct Row: Identifiable {
        var id: Double { silence.start }
        var silence: RecordingSplit.Silence
        var detail: String
    }

    private var rows: [Row] {
        guard let c = choices else { return [] }
        if !c.candidates.isEmpty {
            return c.candidates.map {
                Row(silence: $0.silence, detail: "before: \($0.speakersBefore.joined(separator: ", ")) · after: \($0.speakersAfter.joined(separator: ", "))")
            }
        }
        return c.silences.map { Row(silence: $0, detail: "same speakers either side") }
    }

    private static func clock(_ s: Double) -> String {
        let t = Int(s.rounded())
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Split “\(entry.title)” into two meetings").font(.headline)
            Text("Two new recordings are made from the original and processed into two new notes. The original audio stays where it is, and this note is kept as a backup version.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let result {
                Text(result).fixedSize(horizontal: false, vertical: true)
            } else if let problem {
                Text("Cannot split: \(problem)").foregroundStyle(.secondary)
            } else if choices == nil {
                ProgressView("Looking for silences…")
            } else if rows.isEmpty {
                Text("No silence of a minute or more inside this recording.").foregroundStyle(.secondary)
            } else {
                if choices?.candidates.isEmpty == true {
                    Text("No silence where the speakers change; these are all the silences of a minute or more.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Picker("Cut at", selection: $picked) {
                    ForEach(rows) { row in
                        Text("\(Self.clock(row.silence.start)) · silent \(Self.clock(row.silence.duration)) · \(row.detail)")
                            .tag(Optional(row.silence.start))
                    }
                }
                .pickerStyle(.radioGroup)
            }
            HStack {
                Spacer()
                Button(result == nil ? "Cancel" : "Close") { close() }.keyboardShortcut(.cancelAction)
                if result == nil {
                    Button("Split") { split() }
                        .disabled(picked == nil || working || choices == nil)
                }
            }
        }
        .padding(20)
        .frame(width: 520)
        .task {
            switch await controller.splitChoices(for: entry) {
            case .success(let c):
                choices = c
                picked = (c.candidates.first?.silence ?? c.silences.first)?.start
            case .failure(let why):
                problem = why.errorDescription
            }
        }
    }

    private func split() {
        guard let c = choices, let start = picked, let row = rows.first(where: { $0.silence.start == start }) else { return }
        working = true
        Task {
            result = await controller.splitRecording(entry, choices: c, silence: row.silence)
            working = false
        }
    }
}
