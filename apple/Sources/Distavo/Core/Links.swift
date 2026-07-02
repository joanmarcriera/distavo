import Foundation

/// Outbound links, kept in one place (mirrors the Python `links.py`). The
/// "Support Distavo…" menu item is compiled in only for editions that define
/// `DONATE_ENABLED` (see configs/*.xcconfig) — currently the Direct build only;
/// the Setapp and App Store builds omit the external donate link.
enum Links {
    /// Lemon Squeezy "Pay What You Want" checkout (marcriera store), verified live.
    static let donateURLString = "https://marcriera.lemonsqueezy.com/checkout/buy/e71c4ce2-f423-4bb6-9883-268e2324035d"

    /// `owner/repo` — the single source of truth for the project + issue links.
    /// Lower-case to match the canonical GitHub login (avoids a 301 redirect).
    static let repoSlug = "joanmarcriera/distavo"
    static let projectURLString = "https://github.com/\(repoSlug)"
    /// Third-party licenses for the built-in transcription engine.
    static let noticesURLString = "https://github.com/\(repoSlug)/blob/main/NOTICES.md"

    static let donateURL = URL(string: donateURLString)
}
