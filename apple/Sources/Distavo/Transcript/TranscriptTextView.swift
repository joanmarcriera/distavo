import AppKit
import SwiftUI
import DistavoCore

// The text component of the transcript viewer (Vikunja #2951): an NSTextView
// (TextKit 1, built explicitly so it never silently falls back from TextKit 2)
// showing the whole transcript.
//
//  * Highlight: a TEMPORARY layout-manager attribute on the current token only.
//    Moving it touches the previous and the new range - no text-storage edit,
//    no re-layout - so it stays smooth on a 20k-word transcript.
//  * Click-to-seek: in read mode a click without a drag reports the character
//    index; the model maps it to a time.
//  * Edit mode: plain text; `TranscriptLayout.isAllowedChange` keeps every edit
//    inside one segment paragraph and rejects newlines, so the line structure
//    (and with it the mapping back to segments) never changes.

/// NSTextView that reports clicks and the space bar while read-only.
final class ClickableTextView: NSTextView {
    var onClick: ((Int) -> Void)?
    var onSpace: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)   // runs the selection tracking loop until mouse-up
        guard !isEditable, selectedRange().length == 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        onClick?(characterIndexForInsertion(at: point))
    }

    override func keyDown(with event: NSEvent) {
        if !isEditable, event.charactersIgnoringModifiers == " ", event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
            onSpace?()
        } else {
            super.keyDown(with: event)
        }
    }
}

struct TranscriptTextView: NSViewRepresentable {
    let contentID: Int
    let text: String
    /// Line ranges to style as speaker headers (empty for plain text).
    let headerRanges: [NSRange]
    let headerLineIndices: Set<Int>
    let tokenRange: (Int) -> NSRange?
    let highlight: Int?
    let isEditing: Bool
    let followPlayback: Bool
    let onClick: (Int) -> Void
    let onSpace: () -> Void
    let onTextChange: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        layoutManager.allowsNonContiguousLayout = true
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)

        let tv = ClickableTextView(frame: .zero, textContainer: container)
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.isSelectable = true
        tv.isEditable = false
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.textContainerInset = NSSize(width: 16, height: 14)
        tv.delegate = context.coordinator

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = tv
        scroll.drawsBackground = true
        context.coordinator.attach(tv, scroll)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        guard let tv = c.textView else { return }
        c.parent = self
        tv.onClick = onClick
        tv.onSpace = onSpace

        if c.contentID != contentID {
            c.contentID = contentID
            c.highlighted = nil
            c.setContent(text: text, headers: headerRanges)
            if tv.window?.firstResponder !== tv { tv.window?.makeFirstResponder(tv) }
        }
        if tv.isEditable != isEditing {
            tv.isEditable = isEditing
            if !isEditing { tv.undoManager?.removeAllActions() }
        }

        // Highlight: previous + current range only.
        let wanted = isEditing ? nil : highlight
        if wanted != c.highlighted {
            c.moveHighlight(from: c.highlighted.flatMap(tokenRange), to: wanted.flatMap(tokenRange),
                            scroll: followPlayback && !isEditing)
            c.highlighted = wanted
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TranscriptTextView?
        weak var textView: ClickableTextView?
        var contentID = -1
        var highlighted: Int?
        /// Auto-scroll is suspended until this time after the user scrolls.
        private var userScrollUntil = Date.distantPast
        private var observers: [NSObjectProtocol] = []

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }

        func attach(_ tv: ClickableTextView, _ scroll: NSScrollView) {
            textView = tv
            let nc = NotificationCenter.default
            // A live scroll (wheel / trackpad / scroller drag) pauses follow-along for a few seconds.
            observers.append(nc.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: scroll, queue: .main) { [weak self] _ in
                self?.userScrollUntil = .distantFuture
            })
            observers.append(nc.addObserver(forName: NSScrollView.didEndLiveScrollNotification, object: scroll, queue: .main) { [weak self] _ in
                self?.userScrollUntil = Date().addingTimeInterval(4)
            })
        }

        func setContent(text: String, headers: [NSRange]) {
            guard let tv = textView, let storage = tv.textStorage else { return }
            let body = NSFont.systemFont(ofSize: 14)
            let para = NSMutableParagraphStyle()
            para.lineSpacing = 3
            let attributed = NSMutableAttributedString(string: text, attributes: [
                .font: body, .foregroundColor: NSColor.labelColor, .paragraphStyle: para,
            ])
            let headPara = NSMutableParagraphStyle()
            headPara.paragraphSpacingBefore = 12
            for r in headers where NSMaxRange(r) <= attributed.length {
                attributed.addAttributes([
                    .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .paragraphStyle: headPara,
                ], range: r)
            }
            storage.setAttributedString(attributed)
            tv.typingAttributes = [.font: body, .foregroundColor: NSColor.labelColor, .paragraphStyle: para]
            tv.setSelectedRange(NSRange(location: 0, length: 0))
            tv.scroll(.zero)
        }

        private static let highlightAttributes: [NSAttributedString.Key: Any] = [
            .backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.35),
        ]

        func moveHighlight(from old: NSRange?, to new: NSRange?, scroll: Bool) {
            guard let tv = textView, let lm = tv.layoutManager else { return }
            let length = tv.textStorage?.length ?? 0
            if let old, NSMaxRange(old) <= length { lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: old) }
            guard let new, NSMaxRange(new) <= length else { return }
            lm.addTemporaryAttributes(Self.highlightAttributes, forCharacterRange: new)
            if scroll, Date() >= userScrollUntil { reveal(new) }
        }

        /// Scroll only when the token is outside the visible area, then centre it.
        private func reveal(_ range: NSRange) {
            guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer,
                  let clip = tv.enclosingScrollView?.contentView else { return }
            let glyphs = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var rect = lm.boundingRect(forGlyphRange: glyphs, in: tc)
            rect.origin.y += tv.textContainerInset.height
            let visible = clip.bounds
            if rect.minY >= visible.minY + 24, rect.maxY <= visible.maxY - 24 { return }
            let y = max(0, rect.midY - visible.height / 2)
            clip.setBoundsOrigin(NSPoint(x: 0, y: y))
            tv.enclosingScrollView?.reflectScrolledClipView(clip)
        }

        // MARK: NSTextViewDelegate

        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            guard let replacement = replacementString, let parent else { return true }
            return TranscriptLayout.isAllowedChange(
                in: textView.string, range: range, replacement: replacement, headerLines: parent.headerLineIndices)
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent?.onTextChange(tv.string)
        }
    }
}
