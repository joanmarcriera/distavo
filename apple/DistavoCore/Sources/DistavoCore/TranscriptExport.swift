import Foundation

/// Transcript export formats (Vikunja #2943) rendered from `TranscriptSegments`.
/// Everything here is pure: bytes in, bytes out, no UI, no third-party code.
/// The app's "Export Transcript As…" panel only chooses a format and a file.
public enum TranscriptExportFormat: String, CaseIterable, Sendable {
    case srt, vtt, json, html, docx, pdf

    public var fileExtension: String { rawValue }

    public var displayName: String {
        switch self {
        case .srt: return "SubRip subtitles (.srt)"
        case .vtt: return "WebVTT subtitles (.vtt)"
        case .json: return "JSON with timestamps (.json)"
        case .html: return "Web page (.html)"
        case .docx: return "Word document (.docx)"
        case .pdf: return "PDF document (.pdf)"
        }
    }

    /// Render `transcript`. `title` heads the document formats (HTML/DOCX/PDF).
    public func render(_ input: TranscriptSegments, title: String) throws -> Data {
        // Corrupt timings (NaN, 1e300, end < start) are repaired or dropped
        // here so no exporter can trap on them.
        let transcript = input.sanitised()
        switch self {
        case .srt: return Data(SubtitleExport.srt(transcript).utf8)
        case .vtt: return Data(SubtitleExport.vtt(transcript).utf8)
        case .json: return try transcript.encoded()
        case .html: return Data(TranscriptDocument.html(transcript, title: title).utf8)
        case .docx: return TranscriptDocument.docx(transcript, title: title)
        case .pdf: return TranscriptPDF.render(transcript, title: title)
        }
    }
}

// MARK: - Time formatting

enum TimeFormat {
    /// Finite and within 0...1000 h, so Int conversion can never trap on
    /// corrupt input (1e300, NaN, infinity).
    static func bounded(_ seconds: Double) -> Double {
        seconds.isFinite ? min(max(0, seconds), TranscriptSegments.maxSeconds) : 0
    }

    /// `HH:MM:SS<sep>mmm`, from integer milliseconds so rounding never yields ".1000".
    static func clock(_ seconds: Double, separator: String) -> String {
        let total = Int((bounded(seconds) * 1000).rounded())
        let ms = total % 1000, s = (total / 1000) % 60, m = (total / 60_000) % 60, h = total / 3_600_000
        return String(format: "%02d:%02d:%02d%@%03d", h, m, s, separator, ms)
    }

    /// Compact label for documents: `m:ss`, or `h:mm:ss` from an hour up.
    static func label(_ seconds: Double) -> String {
        let t = Int(bounded(seconds).rounded(.down))
        let h = t / 3600, m = (t / 60) % 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

// MARK: - Subtitles (SRT / WebVTT)

public enum SubtitleExport {
    /// One subtitle cue; its times come straight from the segment (or, for a
    /// long segment split by words, from its first and last word).
    public struct Cue: Equatable {
        public var start: Double
        public var end: Double
        public var speaker: String?
        public var text: String
    }

    /// Limits for one cue (broadcast-style: two lines of ~42 characters, a
    /// few seconds on screen). Only used to split segments that have words.
    public static let maxCueChars = 84
    public static let maxCueSeconds = 7.0
    /// Players dislike zero-length cues; stretch to this much (well inside
    /// the 0.5 s alignment tolerance).
    static let minCueSeconds = 0.4

    /// Cues for the whole transcript. A segment becomes one cue unless it has
    /// word timings AND is longer than the limits, in which case it is split
    /// at word boundaries (preferring sentence ends) so each cue keeps its
    /// words' real times. Segments without words are never split: inventing
    /// interpolated times would break the alignment guarantee.
    public static func cues(_ transcript: TranscriptSegments) -> [Cue] {
        var out: [Cue] = []
        for seg in transcript.segments {
            let text = TranscriptCleaner.normaliseSpace(seg.text)
            guard !text.isEmpty else { continue }
            let tooLong = text.count > maxCueChars || (seg.end - seg.start) > maxCueSeconds
            if tooLong, let words = seg.words, !words.isEmpty {
                out.append(contentsOf: split(words, speaker: seg.speaker))
            } else {
                out.append(Cue(start: seg.start, end: seg.end, speaker: seg.speaker, text: text))
            }
        }
        // Stretch zero-length cues, then keep the list monotonic and
        // non-overlapping: a cue never starts before the previous one began
        // nor ends after the next one starts.
        var fixed = out.map { cue -> Cue in
            var c = cue
            c.start = TimeFormat.bounded(c.start)
            c.end = max(TimeFormat.bounded(c.end), c.start)
            if c.end <= c.start { c.end = c.start + minCueSeconds }
            return c
        }
        for i in fixed.indices.dropFirst() { fixed[i].start = max(fixed[i].start, fixed[i - 1].start) }
        for i in fixed.indices {
            if i + 1 < fixed.count { fixed[i].end = min(fixed[i].end, fixed[i + 1].start) }
            fixed[i].end = max(fixed[i].end, fixed[i].start)
        }
        return fixed
    }

    private static func split(_ words: [TranscriptSegments.Word], speaker: String?) -> [Cue] {
        var cues: [Cue] = []
        var current: [TranscriptSegments.Word] = []
        var length = 0
        func flush() {
            guard let first = current.first, let last = current.last else { return }
            cues.append(Cue(start: first.start, end: last.end, speaker: speaker,
                            text: current.map(\.word).joined(separator: " ")))
            current = []; length = 0
        }
        for word in words {
            let added = word.word.count + (current.isEmpty ? 0 : 1)
            if let first = current.first,
               length + added > maxCueChars || word.end - first.start > maxCueSeconds {
                flush()
            }
            current.append(word)
            length += word.word.count + (current.count > 1 ? 1 : 0)
            // Prefer to close a cue at a sentence end once it has some body.
            if let last = word.word.last, ".?!…".contains(last), length >= 24 { flush() }
        }
        flush()
        return cues
    }

    /// Wrap into at most a few lines of ~42 chars so players lay it out sensibly.
    static func wrapped(_ text: String, width: Int = 42) -> String {
        var lines: [String] = []
        var line = ""
        for word in text.split(separator: " ") {
            if !line.isEmpty && line.count + 1 + word.count > width {
                lines.append(line); line = String(word)
            } else {
                line += (line.isEmpty ? "" : " ") + word
            }
        }
        if !line.isEmpty { lines.append(line) }
        return lines.joined(separator: "\n")
    }

    static func escapeVTT(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    /// SubRip: 1-based index, `HH:MM:SS,mmm --> HH:MM:SS,mmm`, text, blank line.
    /// The speaker prefixes every cue ("SPEAKER_00: …") so a cue read alone is attributed.
    public static func srt(_ transcript: TranscriptSegments) -> String {
        var out = ""
        for (i, cue) in cues(transcript).enumerated() {
            let body = wrapped((cue.speaker.map { "\($0): " } ?? "") + cue.text)
            out += "\(i + 1)\n\(TimeFormat.clock(cue.start, separator: ",")) --> "
                + "\(TimeFormat.clock(cue.end, separator: ","))\n\(body)\n\n"
        }
        return out
    }

    /// WebVTT with `<v Speaker>` voice tags. `&`, `<` and `>` are escaped as
    /// the spec requires for cue text.
    public static func vtt(_ transcript: TranscriptSegments) -> String {
        var out = "WEBVTT\n\n"
        for (i, cue) in cues(transcript).enumerated() {
            let text = escapeVTT(wrapped(cue.text))
            let body: String
            if let speaker = cue.speaker {
                // A voice name is escaped like cue text and must not contain a newline.
                let name = escapeVTT(speaker.replacingOccurrences(of: "\n", with: " "))
                body = "<v \(name)>\(text)</v>"
            } else {
                body = text
            }
            out += "\(i + 1)\n\(TimeFormat.clock(cue.start, separator: ".")) --> "
                + "\(TimeFormat.clock(cue.end, separator: "."))\n\(body)\n\n"
        }
        return out
    }
}

// MARK: - Documents (HTML / DOCX share the same turn grouping)

/// A run of consecutive segments by one speaker, for the document formats.
struct TranscriptTurn: Equatable {
    var speaker: String?
    var start: Double
    var text: String

    /// Merge consecutive same-speaker segments; start a fresh turn when one
    /// would grow past `maxChars` so a long monologue stays readable.
    static func group(_ transcript: TranscriptSegments, maxChars: Int = 900) -> [TranscriptTurn] {
        var turns: [TranscriptTurn] = []
        for seg in transcript.segments {
            let text = TranscriptCleaner.normaliseSpace(seg.text)
            guard !text.isEmpty else { continue }
            if var last = turns.last, last.speaker == seg.speaker, last.text.count + 1 + text.count <= maxChars {
                last.text += " " + text
                turns[turns.count - 1] = last
            } else {
                turns.append(TranscriptTurn(speaker: seg.speaker, start: seg.start, text: text))
            }
        }
        return turns
    }
}

public enum TranscriptDocument {

    static func escapeXML(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default:
                // Control characters other than tab/newline are illegal in XML 1.0.
                if scalar.value < 0x20 && scalar != "\t" && scalar != "\n" && scalar != "\r" { continue }
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// Self-contained HTML5 page: inline CSS only, no scripts, no external
    /// resources; every dynamic string is escaped.
    public static func html(_ transcript: TranscriptSegments, title: String) -> String {
        var body = ""
        for turn in TranscriptTurn.group(transcript) {
            body += "<section class=\"turn\"><p class=\"meta\">"
            if let speaker = turn.speaker { body += "<span class=\"speaker\">\(escapeXML(speaker))</span> " }
            body += "<time>\(TimeFormat.label(turn.start))</time></p>"
            body += "<p>\(escapeXML(turn.text))</p></section>\n"
        }
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escapeXML(title))</title>
        <style>
        :root { color-scheme: light dark; }
        body { font: 16px/1.55 -apple-system, "Helvetica Neue", Arial, sans-serif; max-width: 46rem; margin: 2rem auto; padding: 0 1rem; }
        h1 { font-size: 1.4rem; }
        .turn { margin: 0 0 1.1rem; }
        .turn p { margin: 0; }
        .meta { font-size: .85rem; color: #6b7280; }
        .speaker { font-weight: 700; color: inherit; }
        </style>
        </head>
        <body>
        <h1>\(escapeXML(title))</h1>
        \(body)</body>
        </html>
        """
    }

    /// Minimal valid OOXML: three parts in a stored zip. Per turn, one
    /// paragraph with the speaker label in bold, a grey timestamp, then the text.
    public static func docx(_ transcript: TranscriptSegments, title: String) -> Data {
        func run(_ text: String, bold: Bool = false, size: Int? = nil, grey: Bool = false) -> String {
            var props = ""
            if bold { props += "<w:b/>" }
            if grey { props += "<w:color w:val=\"6B7280\"/>" }
            if let size { props += "<w:sz w:val=\"\(size)\"/>" }
            let rPr = props.isEmpty ? "" : "<w:rPr>\(props)</w:rPr>"
            return "<w:r>\(rPr)<w:t xml:space=\"preserve\">\(escapeXML(text))</w:t></w:r>"
        }
        var paragraphs = "<w:p>\(run(title, bold: true, size: 32))</w:p>"
        for turn in TranscriptTurn.group(transcript) {
            var p = "<w:p>"
            if let speaker = turn.speaker { p += run(speaker, bold: true) + run("  ") }
            p += run("[\(TimeFormat.label(turn.start))]", grey: true)
            p += "</w:p><w:p>\(run(turn.text))</w:p>"
            paragraphs += p
        }
        let document = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>\(paragraphs)<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="708" w:footer="708" w:gutter="0"/></w:sectPr></w:body></w:document>
        """
        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>
        """
        let rels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>
        """
        var zip = StoredZipWriter()
        // [Content_Types].xml first, as Word expects.
        zip.add(name: "[Content_Types].xml", data: Data(contentTypes.utf8))
        zip.add(name: "_rels/.rels", data: Data(rels.utf8))
        zip.add(name: "word/document.xml", data: Data(document.utf8))
        return zip.finish()
    }
}
