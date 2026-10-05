import SwiftUI
#if EDITION_DIRECT
import DistavoCore
#endif

/// Process entry point. It exists only so the Direct edition can answer
/// `Distavo.app/Contents/MacOS/Distavo transcribe …` (Vikunja #2955) BEFORE any
/// SwiftUI/AppKit UI, menu-bar item, watcher, timer or notification exists.
///
/// In the App Store and Setapp builds the `#if` is compiled out and this is just
/// `DistavoApp.main()`, exactly what `@main` on `DistavoApp` did before. In Direct,
/// ONLY a first argument that is exactly a CLI verb diverts; everything macOS passes
/// to a launched app (`-psn_…`, `-NSDocumentRevisionsDebugMode`, `-AppleLanguages`,
/// `-ApplePersistenceIgnoreState`) falls through to the normal app.
@main
enum DistavoMain {
    @MainActor
    static func main() {
        #if EDITION_DIRECT
        let args = Array(CommandLine.arguments.dropFirst())
        if CLIArguments.isCLIInvocation(args) {
            DistavoCLI.runAndExit(args)   // never returns
        }
        #endif
        DistavoApp.main()
    }
}
