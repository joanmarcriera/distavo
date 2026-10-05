import Foundation
import CoreGraphics
import CoreText

/// PDF export (Vikunja #2943): the transcript typeset with CoreText onto A4
/// pages, speaker labels in bold, timestamps in grey. Pure CoreGraphics /
/// CoreText (system frameworks, no AppKit, no window), so it runs offscreen and
/// is unit-tested in `swift test`. Lives in DistavoCore rather than the app
/// target for exactly that reason.
public enum TranscriptPDF {
    private static let pageSize = CGSize(width: 595.28, height: 841.89)   // A4 in points
    private static let margin: CGFloat = 54

    public static func render(_ transcript: TranscriptSegments, title: String) -> Data {
        let text = attributedText(transcript, title: title)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return Data() }
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        let info = [kCGPDFContextTitle as String: title] as CFDictionary
        guard let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, info) else { return Data() }

        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let textRect = mediaBox.insetBy(dx: margin, dy: margin)
        let length = CFAttributedStringGetLength(text)
        var location = 0
        repeat {
            ctx.beginPDFPage(nil)
            let frame = CTFramesetterCreateFrame(
                framesetter, CFRange(location: location, length: 0), CGPath(rect: textRect, transform: nil), nil)
            CTFrameDraw(frame, ctx)
            ctx.endPDFPage()
            let visible = CTFrameGetVisibleStringRange(frame)
            if visible.length == 0 { break }   // nothing fits (cannot happen with sane fonts); avoid looping
            location += visible.length
        } while location < length
        ctx.closePDF()
        return data as Data
    }

    /// Title, then per turn: `Speaker  m:ss` line and the paragraph text.
    static func attributedText(_ transcript: TranscriptSegments, title: String) -> CFAttributedString {
        let regular = CTFontCreateWithName("Helvetica" as CFString, 11, nil)
        let bold = CTFontCreateWithName("Helvetica-Bold" as CFString, 11, nil)
        let heading = CTFontCreateWithName("Helvetica-Bold" as CFString, 16, nil)
        let grey = CGColor(gray: 0.45, alpha: 1)
        let black = CGColor(gray: 0, alpha: 1)

        func paragraphStyle(after: CGFloat) -> CTParagraphStyle {
            var spacing = after
            return withUnsafePointer(to: &spacing) { ptr in
                let setting = CTParagraphStyleSetting(
                    spec: .paragraphSpacing, valueSize: MemoryLayout<CGFloat>.size, value: ptr)
                return CTParagraphStyleCreate([setting], 1)
            }
        }

        let out = NSMutableAttributedString()
        func append(_ s: String, font: CTFont, color: CGColor, style: CTParagraphStyle) {
            out.append(NSAttributedString(string: s, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
                NSAttributedString.Key(kCTParagraphStyleAttributeName as String): style,
            ]))
        }

        append(title + "\n", font: heading, color: black, style: paragraphStyle(after: 12))
        let tight = paragraphStyle(after: 1), loose = paragraphStyle(after: 10)
        for turn in TranscriptTurn.group(transcript) {
            // One CTParagraphStyle applies per paragraph, so the label line and
            // the body each carry their own newline-terminated run.
            if let speaker = turn.speaker {
                append(speaker, font: bold, color: black, style: tight)
                append("  \(TimeFormat.label(turn.start))\n", font: regular, color: grey, style: tight)
            } else {
                append("\(TimeFormat.label(turn.start))\n", font: regular, color: grey, style: tight)
            }
            append(turn.text + "\n", font: regular, color: black, style: loose)
        }
        return out
    }
}
