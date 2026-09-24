import SwiftUI
import AppKit
import DistavoCore

/// "Compare two models" (Vikunja #2201): two panes, each picking one of a
/// recording's runs (the automatic one plus every "Process a recording
/// with…" variant, via `RecordingVariants.list`), showing the rendered note
/// or the cleaned transcript with synced scrolling. Purely a viewer over
/// files already on disk — it starts nothing and changes nothing.
struct CompareView: View {
    let recordingName: String
    let variants: [RecordingVariant]

    @State private var leftIndex: Int
    @State private var rightIndex: Int
    @State private var showTranscript = false
    /// 0...1 vertical position, shared by both panes so scrolling one
    /// scrolls the other to the same fraction (see `MarkdownScrollPane`).
    @State private var scrollFraction: CGFloat = 0

    init(recordingName: String, variants: [RecordingVariant]) {
        self.recordingName = recordingName
        self.variants = variants
        _leftIndex = State(initialValue: 0)
        _rightIndex = State(initialValue: variants.count > 1 ? 1 : 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(recordingName).font(.headline)
                Spacer()
                Picker("", selection: $showTranscript) {
                    Text("Notes").tag(false)
                    Text("Transcripts").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
                .labelsHidden()
            }
            .padding(10)
            Divider()
            HSplitView {
                pane(index: $leftIndex)
                pane(index: $rightIndex)
            }
        }
        .frame(minWidth: 900, minHeight: 560)
    }

    @ViewBuilder
    private func pane(index: Binding<Int>) -> some View {
        let variant = variants[index.wrappedValue]
        let path = showTranscript ? variant.transcriptPath : variant.notePath
        let text = path.flatMap { try? String(contentsOf: $0, encoding: .utf8) }

        VStack(spacing: 0) {
            HStack {
                Picker("", selection: index) {
                    ForEach(Array(variants.enumerated()), id: \.offset) { i, v in
                        Text(headerTitle(v)).tag(i)
                    }
                }
                .labelsHidden()
                Spacer()
                if let text {
                    Text("\(wordCount(text)) words")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(8)
            Divider()
            if let text {
                MarkdownScrollPane(text: text, plain: showTranscript, scrollFraction: $scrollFraction)
            } else {
                Spacer()
                Text(showTranscript
                     ? "No cleaned transcript on disk for this run — it may have been cleared."
                     : "No note on disk for this run.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
                Spacer()
            }
        }
        .frame(minWidth: 420)
    }

    /// "bsc-los-ca" → "Català · Castellà · Galego · Euskara (BSC Languages of Spain) — Catalan";
    /// the automatic run → "Automatic".
    private func headerTitle(_ v: RecordingVariant) -> String {
        guard v.label != "Automatic" else { return "Automatic" }
        var parts = [v.modelLabel ?? v.label]
        if let lang = v.languageCode, let name = WhisperLanguageCatalog.language(forCode: lang)?.englishName {
            parts.append(name)
        }
        return parts.joined(separator: " — ")
    }

    private func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }
}
