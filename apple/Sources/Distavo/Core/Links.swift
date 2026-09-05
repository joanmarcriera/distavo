import Foundation

/// Outbound links, kept in one place (mirrors the Python `links.py`). The
/// "Support Distavo…" menu item is compiled in only for editions that define
/// `DONATE_ENABLED` (see configs/*.xcconfig) — currently the Direct build only;
/// the Setapp and App Store builds omit the external donate link.
enum Links {
    /// Lemon Squeezy "Pay What You Want" checkout (marcriera store), verified live.
    static let donateURLString = "https://marcriera.lemonsqueezy.com/checkout/buy/f5f7099b-cf47-43a4-98e4-3dcbe64933c8"

    /// `owner/repo` — the single source of truth for the project + issue links.
    /// Lower-case to match the canonical GitHub login (avoids a 301 redirect).
    static let repoSlug = "joanmarcriera/distavo"
    static let projectURLString = "https://github.com/\(repoSlug)"
    /// Third-party licenses for the built-in transcription engine.
    static let noticesURLString = "https://github.com/\(repoSlug)/blob/main/NOTICES.md"

    /// Feedback form on the product site. Direct-edition only (`EDITION_DIRECT`)
    /// per the product decision — the App Store and Setapp builds keep their
    /// outbound links limited to the GitHub issue tracker.
    /// Trailing slash is canonical: `/feedback` 301-redirects to `/feedback/`.
    static let feedbackURLString = "https://distavo.com/feedback/"

    static let donateURL = URL(string: donateURLString)
}
