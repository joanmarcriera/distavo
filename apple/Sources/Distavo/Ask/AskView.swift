import SwiftUI
import DistavoCore

/// The "Ask Your Notes" window (Vikunja #2948): scope picker, chat messages with
/// clickable citations, input, Stop. Answers come from a local model only.
struct AskView: View {
    @ObservedObject var model: AskModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Ask about", selection: $model.searchAllNotes) {
                    Text("All notes").tag(true)
                    Text("This note").tag(false)
                }
                .pickerStyle(.segmented).frame(maxWidth: 260)
                if !model.searchAllNotes {
                    Picker("Note", selection: $model.selectedBase) {
                        ForEach(model.notes) { Text($0.title).tag($0.base) }
                    }
                    .labelsHidden().frame(maxWidth: 320)
                }
                Spacer()
                Button("Clear chat") { model.clear() }.disabled(model.messages.isEmpty)
            }
            .padding(12)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if model.messages.isEmpty {
                            Text("Ask a question about your meetings, e.g. “What did we decide about pricing?”. The answer cites the notes it came from.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(model.messages) { m in
                            AskBubble(message: m, model: model).id(m.id)
                        }
                        if model.busy {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Thinking on this Mac…").foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: model.messages.count) { _, _ in
                    if let last = model.messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            Divider()
            HStack(spacing: 8) {
                TextField("Ask about your notes", text: $model.input, axis: .vertical)
                    .lineLimit(1...4).textFieldStyle(.roundedBorder).focused($focused)
                    .onSubmit { model.send() }
                if model.busy {
                    Button("Stop") { model.stop() }
                } else {
                    Button("Ask") { model.send() }.disabled(!model.canSend)
                }
            }
            .padding(12)
            Text("Answered by a local model on this Mac or your local network — nothing leaves it. This chat is kept in memory only while this window is open; nothing is saved.")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.bottom, 8).frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 520, minHeight: 420)
        .onAppear { focused = true }
    }
}

private struct AskBubble: View {
    let message: AskMessage
    @ObservedObject var model: AskModel

    var body: some View {
        switch message.role {
        case .user:
            Text(message.text).textSelection(.enabled)
                .padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .notice:
            VStack(alignment: .leading, spacing: 6) {
                Label(message.text, systemImage: "info.circle").foregroundStyle(.secondary)
                if message.offersIndex {
                    Button("Build the search index") { model.enableIndex() }.disabled(model.busy)
                }
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 6) {
                Text(rendered(message.text)).textSelection(.enabled)
                if message.citations.isEmpty {
                    Text("The answer cited no source. Notes the model was shown:")
                        .font(.caption).foregroundStyle(.secondary)
                    sources(message.consulted)
                } else {
                    sources(message.citations)
                }
                Text("Answered locally by \(message.backend ?? "a local model")" + (message.method.map { " · from \($0)" } ?? ""))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(8).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func sources(_ list: [AskCitation]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(list, id: \.key) { c in
                Button { model.open(c) } label: {
                    Text("[\(c.key)] \(c.title)" + (c.timeLabel.map { " · at \($0)" } ?? "")
                         + (c.kind == .transcript ? " · transcript" : ""))
                        .lineLimit(1)
                }
                .buttonStyle(.link).help("Open \(c.path.lastPathComponent)")
            }
        }
    }

    private func rendered(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}
