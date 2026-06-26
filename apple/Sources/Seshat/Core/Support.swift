import Foundation
import SeshatCore

/// Builds the "Report an Issue" target: a pre-filled GitHub new-issue URL whose
/// body carries the non-sensitive diagnostics that make a bug report — especially
/// a *performance* report — actionable (app version, edition, macOS version, Mac
/// hardware). Available in every edition: GitHub issue reporting is allowed by the
/// App Store and Setapp, unlike the external donate link.
///
/// Deliberately carries **no log content or file names** — only system facts — so
/// nothing private is ever auto-attached. Users can attach log lines themselves.
enum Support {

    /// Which build this is, from the compile-time edition flags.
    static var edition: String {
        #if EDITION_DIRECT
        return "Direct"
        #elseif EDITION_SETAPP
        return "Setapp"
        #elseif EDITION_APPSTORE
        return "App Store"
        #else
        return "Unknown"
        #endif
    }

    /// CPU architecture this binary is built for.
    static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    /// A short, non-sensitive diagnostics block.
    static func diagnostics() -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osString = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let ramGB = ProcessInfo.processInfo.physicalMemory / 1_073_741_824
        return """
        - App: Seshat \(version) (build \(build))
        - Edition: \(edition)
        - macOS: \(osString)
        - Hardware: \(architecture) · \(cores) cores · \(ramGB) GB
        """
    }

    /// The Markdown body that pre-fills the GitHub issue form.
    static func issueBody() -> String {
        """
        ### What happened?


        ### Steps to reproduce


        ### Diagnostics
        \(diagnostics())

        _Tip: if this is about speed or stuck processing, attach lines from your \
        log — menu ▸ Activity ▸ Open full log…_
        """
    }

    /// The pre-filled GitHub "New issue" URL, or nil if it can't be built.
    static func issueURL() -> URL? {
        IssueReport.githubNewIssueURL(
            repoSlug: Links.repoSlug, title: "Issue: ", body: issueBody())
    }
}
