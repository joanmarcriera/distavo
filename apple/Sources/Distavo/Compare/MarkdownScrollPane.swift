import AppKit
import SwiftUI

/// A read-only, scrollable text pane for `CompareView`: renders Markdown
/// (the note) or plain monospaced text (the transcript), and keeps its
/// scroll position in sync with a sibling pane via a shared `scrollFraction`
/// binding (0...1 of the scrollable range) — an `NSViewRepresentable`
/// because SwiftUI's `ScrollView` has no public API to read or drive an
/// exact scroll offset at this deployment target (macOS 14).
struct MarkdownScrollPane: NSViewRepresentable {
    let text: String
    let plain: Bool
    @Binding var scrollFraction: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(scrollFraction: $scrollFraction) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 14, height: 14)
        // Standard manual (non-`scrollableTextView()`) scrollable-NSTextView
        // wiring: without these, the document view keeps a zero/undefined
        // frame and nothing ever paints — it isn't enough to just assign
        // `scrollView.documentView`.
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.documentView = textView
        scrollView.contentView.postsBoundsChangedNotifications = true

        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView
        NotificationCenter.default.addObserver(
            context.coordinator, selector: #selector(Coordinator.userDidScroll),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        if context.coordinator.lastRenderedText != text || context.coordinator.lastRenderedPlain != plain {
            context.coordinator.lastRenderedText = text
            context.coordinator.lastRenderedPlain = plain
            context.coordinator.textView?.textStorage?.setAttributedString(Self.render(text, plain: plain))
        }
        context.coordinator.applyExternalScroll(fraction: scrollFraction)
    }

    /// Deliberately NOT `AttributedString(markdown:options:.full)` bridged
    /// through `NSMutableAttributedString(_:)`: Foundation's Markdown parser
    /// records block boundaries (a heading ending, a new paragraph, a list
    /// item) as `PresentationIntent` metadata rather than literal newline
    /// characters — `Text(AttributedString(markdown:))` in pure SwiftUI
    /// understands that metadata and lays out paragraphs correctly, but
    /// `NSMutableAttributedString(_:)` drops it, so `NSTextView` renders
    /// every block run on as one unbroken sentence. Distavo's own notes only
    /// ever use `#`/`##`/`###` headings and `-` bullets (see `Prompt.swift`),
    /// so a line-based renderer over the text's own real newlines covers
    /// them exactly, without that bridging bug.
    private static func render(_ text: String, plain: Bool) -> NSAttributedString {
        if plain {
            return NSAttributedString(string: text, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor.labelColor,
            ])
        }
        let bodyFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let result = NSMutableAttributedString()
        let lines = text.components(separatedBy: "\n")
        for (i, rawLine) in lines.enumerated() {
            var line = Substring(rawLine)
            var font = bodyFont
            var prefix = ""
            if line.hasPrefix("### ") {
                font = .boldSystemFont(ofSize: NSFont.systemFontSize + 1); line = line.dropFirst(4)
            } else if line.hasPrefix("## ") {
                font = .boldSystemFont(ofSize: NSFont.systemFontSize + 3); line = line.dropFirst(3)
            } else if line.hasPrefix("# ") {
                font = .boldSystemFont(ofSize: NSFont.systemFontSize + 6); line = line.dropFirst(2)
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                prefix = "•  "; line = line.dropFirst(2)
            }
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = font.pointSize > bodyFont.pointSize ? 6 : 2
            result.append(NSAttributedString(string: prefix + String(line), attributes: [
                .font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: style,
            ]))
            if i < lines.count - 1 { result.append(NSAttributedString(string: "\n")) }
        }
        return result
    }

    @MainActor
    final class Coordinator: NSObject {
        weak var textView: NSTextView?
        weak var scrollView: NSScrollView?
        var lastRenderedText: String?
        var lastRenderedPlain: Bool?
        private var isApplyingExternalScroll = false
        private let binding: Binding<CGFloat>

        init(scrollFraction: Binding<CGFloat>) { self.binding = scrollFraction }

        /// The clip view's bounds changed (a user scroll, or one of ours via
        /// `applyExternalScroll` — guarded off by `isApplyingExternalScroll`
        /// so it doesn't feed back into the binding it just consumed).
        @objc func userDidScroll() {
            guard !isApplyingExternalScroll, let scrollView, let doc = scrollView.documentView else { return }
            let range = max(1, doc.bounds.height - scrollView.contentView.bounds.height)
            binding.wrappedValue = min(1, max(0, scrollView.contentView.bounds.origin.y / range))
        }

        func applyExternalScroll(fraction: CGFloat) {
            guard let scrollView, let doc = scrollView.documentView else { return }
            let range = max(1, doc.bounds.height - scrollView.contentView.bounds.height)
            let target = range * fraction
            guard abs(scrollView.contentView.bounds.origin.y - target) > 1 else { return }
            isApplyingExternalScroll = true
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: target))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            isApplyingExternalScroll = false
        }
    }
}
