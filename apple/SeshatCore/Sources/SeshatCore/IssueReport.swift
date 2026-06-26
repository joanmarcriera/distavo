import Foundation

/// Builds the URL for a pre-filled GitHub "New issue" page. Pure and UI-free so
/// it can be unit-tested without servers or the app target; the app layer
/// supplies the diagnostics title/body and edition. Visiting the URL opens the
/// GitHub issue form with the title and body already populated.
public enum IssueReport {

    /// Characters left unescaped in a query value: the RFC 3986 *unreserved* set,
    /// ASCII-only. Deliberately spelled out rather than using
    /// `CharacterSet.alphanumerics` (which also matches Unicode letters/digits, so
    /// an accented character would slip through un-encoded) — this guarantees every
    /// non-ASCII byte *and* the query sub-delimiters (`& = + #` …) is percent-
    /// encoded, so any title/body round-trips and never corrupts the query.
    private static let queryValueAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// e.g. `githubNewIssueURL(repoSlug: "Joanmarcriera/seshat", title: …, body: …)`
    /// → `https://github.com/Joanmarcriera/seshat/issues/new?title=…&body=…`.
    public static func githubNewIssueURL(repoSlug: String, title: String, body: String) -> URL? {
        func encode(_ value: String) -> String {
            value.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) ?? ""
        }
        let query = "title=\(encode(title))&body=\(encode(body))"
        return URL(string: "https://github.com/\(repoSlug)/issues/new?\(query)")
    }
}
