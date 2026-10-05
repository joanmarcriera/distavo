import SwiftUI
import DistavoCore

/// The "Search Notes" window (Vikunja #2942): search field (search-as-you-type),
/// kind and speaker filters, and a result list with the match emphasised.
/// Return or double-click opens the note; Up/Down move the selection while the
/// field keeps focus (the List would only get arrow keys after a click).
struct SearchView: View {
    @ObservedObject var model: SearchModel
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search notes and transcripts", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($fieldFocused)
                    .onSubmit { model.openSelected() }
                    .onKeyPress(.downArrow) { model.moveSelection(1); return .handled }
                    .onKeyPress(.upArrow) { model.moveSelection(-1); return .handled }
                if model.busy { ProgressView().controlSize(.small) }
                Menu {
                    Button("Rebuild search index") { model.refresh(rebuild: true) }
                    Button("Delete search index", role: .destructive) { model.deleteIndex() }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help("The index holds your note and transcript text, on this Mac only.")
            }
            .padding(12)
            HStack {
                Picker("Search in", selection: $model.kindFilter) {
                    ForEach(SearchModel.KindFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 320)
                Picker("Speaker", selection: $model.speaker) {
                    Text("Any speaker").tag(String?.none)
                    ForEach(model.speakers, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                .frame(maxWidth: 200)
                Spacer()
                Text(model.message).font(.callout).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.bottom, 8)
            Divider()
            List(selection: $model.selection) {
                ForEach(model.hits, id: \.path) { hit in
                    SearchRow(hit: hit)
                        .tag(hit.path)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { model.open(hit) }
                }
            }
            .listStyle(.inset)
            Divider()
            Text("Search keeps a local index of your notes and transcripts on this Mac. It is created when you first open this window; “Delete search index” removes it, and nothing is indexed again until you open Search Notes… again.")
                .font(.caption).foregroundStyle(.secondary)
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 520, minHeight: 360)
        .onAppear { fieldFocused = true }
        .onChange(of: model.query) { _, _ in model.scheduleSearch() }
        .onChange(of: model.kindFilter) { _, _ in model.scheduleSearch() }
        .onChange(of: model.speaker) { _, _ in model.scheduleSearch() }
    }
}

private struct SearchRow: View {
    let hit: SearchHit

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(hit.title).fontWeight(.semibold).lineLimit(1)
                Text(hit.kind == .note ? "Note" : "Transcript")
                    .font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                Spacer()
                Text(hit.date, style: .date).font(.caption).foregroundStyle(.secondary)
            }
            Text(Self.highlighted(hit.snippet)).font(.callout).foregroundStyle(.secondary).lineLimit(3)
        }
        .padding(.vertical, 3)
    }

    /// Snippet with the matched terms bold + tinted (AttributedString, not `Text +`).
    static func highlighted(_ snippet: String) -> AttributedString {
        var out = AttributedString()
        for run in SearchIndex.snippetRuns(snippet.replacingOccurrences(of: "\n", with: " ")) {
            var piece = AttributedString(run.text)
            if run.match {
                piece.font = .callout.bold()
                piece.foregroundColor = .accentColor
            }
            out.append(piece)
        }
        return out
    }
}
