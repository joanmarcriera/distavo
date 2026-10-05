import Foundation

// Neutralises text that came from outside the program before it reaches a terminal or a
// log (Vikunja #2955). Transcript text, speaker labels, file names, engine/error messages,
// HTTP headers, feed titles and URLs are all attacker-influenceable; written raw to a
// terminal, ESC/CSI/OSC sequences can rewrite the screen, set the window title, or (OSC 8
// hyperlinks, OSC 52 clipboard) do worse, and a lone CR can overwrite a line.
//
// Policy: keep `\n` and `\t`; replace every other C0 control (including ESC and CR), DEL,
// every C1 control (U+0080-U+009F) and the bidi override/isolate/mark characters with a
// visible, inert stand-in (Unicode "control pictures" or a `<U+XXXX>` marker). A CRLF pair
// is kept as a single newline. Pure; used by the Direct CLI, the MCP server logger and the
// URL importer.

public enum TerminalSafe {

    /// True for scalars that must not reach a terminal unescaped.
    static func isDangerous(_ s: Unicode.Scalar) -> Bool {
        let v = s.value
        switch v {
        case 0x0a, 0x09: return false
        case 0x00...0x1f, 0x7f, 0x80...0x9f: return true
        case 0x061c, 0x200e, 0x200f, 0x202a...0x202e, 0x2066...0x2069: return true   // bidi
        case 0x2028, 0x2029: return true                                              // line/paragraph separators
        default: return false
        }
    }

    /// `text` with every dangerous scalar made visible and inert.
    public static func neutralised(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        var previousWasCR = false
        for s in text.unicodeScalars {
            defer { previousWasCR = (s.value == 0x0d) }
            if s.value == 0x0a, previousWasCR { out.removeLast(); out.append(s); continue }   // CRLF -> LF
            guard isDangerous(s) else { out.append(s); continue }
            if s.value < 0x20, let pic = Unicode.Scalar(0x2400 + s.value) {
                out.append(pic)                       // U+2400..U+241F control pictures (ESC -> U+241B)
            } else if s.value == 0x7f, let pic = Unicode.Scalar(0x2421) {
                out.append(pic)
            } else {
                out.append(contentsOf: String(format: "<U+%04X>", s.value).unicodeScalars)
            }
        }
        return String(out)
    }

    /// What to write for transcript/payload text bound for `stdout`: faithful when it goes to a
    /// file or a pipe, neutralised when a terminal would interpret it.
    public static func forSink(_ text: String, isTerminal: Bool) -> String {
        isTerminal ? neutralised(text) : text
    }
}
