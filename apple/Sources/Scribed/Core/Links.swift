import Foundation

/// Outbound links, kept in one place (mirrors the Python `links.py`). The donate
/// URL is empty until the Lemon Squeezy "Pay What You Want" product exists; the
/// Support menu item is additionally compiled in only for editions that define
/// `DONATE_ENABLED` (see configs/*.xcconfig), so the Setapp build omits it.
enum Links {
    /// Paste the Lemon Squeezy "Buy now" URL, e.g.
    /// "https://marcriera.lemonsqueezy.com/buy/<variant-uuid>".
    static let donateURLString = ""
    static let projectURLString = "https://github.com/Joanmarcriera/scribed"

    static var donateURL: URL? {
        let trimmed = donateURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : URL(string: trimmed)
    }
}
