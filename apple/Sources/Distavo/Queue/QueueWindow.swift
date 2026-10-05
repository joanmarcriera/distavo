import AppKit
import SwiftUI
import DistavoCore

// Processing Queue window (Vikunja #2952): a resizable window listing every
// recording the scan knows about (copying / waiting / running / done / failed ...),
// a drop target for audio and video files, and per-row actions. All logic lives in
// WatcherController+Queue.swift and DistavoCore's `ProcessingQueue`; this file is
// presentation only. A plain SwiftUI `List` is used rather than an AppKit table:
// the model publishes at most ~4 times a second and the list holds tens of rows,
// not thousands, so nothing here needs NSTableView's recycling.

/// Hosts `QueueView` in one reusable window (same pattern as `CompareWindowController`).
@MainActor
final class QueueWindowController: NSObject, NSWindowDelegate {
    static let shared = QueueWindowController()
    private var window: NSWindow?

    func show(_ controller: WatcherController) {
        if window == nil {
            let hosting = NSHostingController(rootView: QueueView(controller: controller, model: controller.queueModel))
            let w = NSWindow(contentViewController: hosting)
            w.title = "Processing Queue"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.setContentSize(NSSize(width: 760, height: 480))
            w.minSize = NSSize(width: 560, height: 320)
            w.center()
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Dropping the hosting view cancels its refresh task; the next show() rebuilds it.
        window?.contentViewController = nil
        window = nil
        NSApp.setActivationPolicy(.accessory)
    }
}

struct QueueView: View {
    @ObservedObject var controller: WatcherController
    @ObservedObject var model: QueueModel
    @State private var dropTargeted = false

    private var items: [QueueItem] { model.queue.items }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if items.isEmpty {
                emptyState
            } else {
                List(items) { item in
                    QueueRow(item: item, queue: model.queue, controller: controller)
                }
                .listStyle(.inset)
            }
            Divider()
            footer
        }
        .overlay { if dropTargeted { dropOverlay } }
        .dropDestination(for: URL.self) { urls, _ in
            controller.enqueueDrop(urls)
            return !urls.isEmpty
        } isTargeted: { dropTargeted = $0 }
        // Re-read the folder and markers every 3 s while the window is open.
        .task {
            while !Task.isCancelled {
                await controller.refreshQueue()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button(controller.isPaused ? "Resume" : "Pause") { controller.toggleQueuePause() }
                .help(controller.isPaused
                      ? "Resume processing."
                      : "Finish the file in progress, then hold. Same switch as “Pause watching”; it resets when Distavo restarts.")
            Button("Process now") { controller.processNow() }
                .disabled(controller.isPaused)
                .help(controller.isPaused ? "Resume first: a paused queue starts nothing."
                                          : "Scan the folder now and retry every failed recording.")
            Button("Clear finished") { controller.clearFinishedQueueItems() }
                .disabled(!items.contains { $0.state == .done || $0.state == .skipped })
            Spacer()
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(summary(now: ctx.date)).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(10)
    }

    private func summary(now: Date) -> String {
        let waiting = items.filter { $0.state == .waiting }.count
        let running = items.filter { $0.state.isRunning }.count
        if controller.isPaused { return "Paused - \(waiting + running) waiting" }
        var text = "\(running + waiting) to process"
        if let eta = model.queue.totalETA(now: now) { text += ", \(ProcessingQueue.etaLabel(eta)) left" }
        return text
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray.and.arrow.down").font(.system(size: 34)).foregroundStyle(.secondary)
            Text("Drop audio or video files here").font(.headline)
            Text("They are copied into your recordings folder and processed one at a time.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let notice = model.notice {
                Text(notice).font(.caption).foregroundStyle(.orange)
            }
            if controller.isPaused {
                Text("Paused until you resume or quit Distavo (a pause is not remembered across launches).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Drop files or use the context menu on a row. “Skip” only affects this session: the file stays in the folder and is offered again next launch. A file that is already being processed cannot be stopped.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    private var dropOverlay: some View {
        RoundedRectangle(cornerRadius: 10)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
            .background(Color.accentColor.opacity(0.08))
            .overlay(Text("Drop to add to the queue").font(.title3).bold())
            .padding(6)
            .allowsHitTesting(false)
    }
}

private struct QueueRow: View {
    let item: QueueItem
    let queue: ProcessingQueue
    let controller: WatcherController

    private var isVariant: Bool { item.base.contains("@") }
    private var canRetry: Bool { (item.state == .failed || item.state == .deferred) && !isVariant }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName).lineLimit(1).truncationMode(.middle)
                if !item.message.isEmpty && item.state != .done {
                    Text(item.message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(label).font(.callout)
                if item.state.isRunning {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        progress(now: ctx.date)
                    }
                } else if item.state == .waiting {
                    TimelineView(.periodic(from: .now, by: 5)) { ctx in
                        if let eta = queue.eta(for: item, now: ctx.date) {
                            Text(ProcessingQueue.etaLabel(eta)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(minWidth: 130, alignment: .trailing)
            inlineAction
        }
        .padding(.vertical, 2)
        .contextMenu { menu }
    }

    @ViewBuilder private func progress(now: Date) -> some View {
        // Honest progress: a bar and "about N min" only once a rate has been learned.
        if let eta = queue.eta(for: item, now: now), let p = item.progress {
            ProgressView(value: p).frame(width: 110)
            Text(ProcessingQueue.etaLabel(eta)).font(.caption).foregroundStyle(.secondary)
        } else {
            ProgressView().controlSize(.small)
        }
    }

    @ViewBuilder private var inlineAction: some View {
        if canRetry {
            Button("Retry") { controller.retryQueueItem(item.base) }.controlSize(.small)
        } else if item.state == .waiting {
            Button("Skip") { controller.cancelQueueItem(item.base) }.controlSize(.small)
                .help("Skip for this session. The file stays in the folder and is offered again next launch.")
        } else if item.state == .cancelled {
            Button("Restore") { controller.restoreQueueItem(item.base) }.controlSize(.small)
        }
    }

    @ViewBuilder private var menu: some View {
        if canRetry {
            Button("Retry") { controller.retryQueueItem(item.base) }
        }
        if item.state == .waiting {
            Button("Skip for this session") { controller.cancelQueueItem(item.base) }
        }
        if item.state.isRunning {
            Button("Cancel (not possible while a file is being processed)") {}.disabled(true)
        }
        if item.state == .cancelled { Button("Restore") { controller.restoreQueueItem(item.base) } }
        if !isVariant && !item.state.isRunning && item.state != .copying {
            Button("Reprocess with another model or language…") { controller.reprocessQueueItem(item.base) }
        }
        if item.state != .copying {
            Divider()
            Button("Reveal in Finder") { controller.revealQueueItem(item.base) }
            Button("Open note") { controller.openQueueNote(item.base) }
        }
        if !isVariant && !item.state.isRunning && item.state != .copying {
            Divider()
            Button("Move recording to the Bin") { controller.trashQueueItem(item.base) }
        }
    }

    private var label: String {
        switch item.state {
        case .waiting: return "Waiting"
        case .copying: return "Copying"
        case .converting: return "Converting audio"
        case .transcribing: return "Transcribing"
        case .summarising: return "Summarising"
        case .done: return "Done"
        case .deferred: return "Waiting to retry"
        case .failed: return "Failed"
        case .tooShort: return "Too short"
        case .cancelled, .skipped: return "Skipped"
        }
    }

    private var symbol: String {
        switch item.state {
        case .waiting: return "clock"
        case .copying: return "doc.on.doc"
        case .converting, .transcribing, .summarising: return "waveform"
        case .done: return "checkmark.circle.fill"
        case .deferred: return "pause.circle"
        case .failed: return "exclamationmark.triangle.fill"
        case .tooShort: return "scissors"
        case .cancelled, .skipped: return "forward.circle"
        }
    }

    private var tint: Color {
        switch item.state {
        case .done: return .green
        case .failed: return .red
        case .deferred, .tooShort: return .orange
        case .converting, .transcribing, .summarising, .copying: return .accentColor
        default: return .secondary
        }
    }
}
