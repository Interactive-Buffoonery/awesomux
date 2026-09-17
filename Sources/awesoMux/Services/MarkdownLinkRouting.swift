import Foundation

/// Pure router: decides whether a URL clicked inside a markdown document pane
/// should open a new document pane or go through the external URL classifier.
///
/// Kept free of AppKit, `@MainActor`, and side effects so the logic can be
/// driven from unit tests without a running app. Wiring lives in
/// `MarkdownTextViewCoordinator.textView(_:clickedOnLink:at:)`.
enum MarkdownLinkRouting {
    enum Route: Equatable {
        /// The URL points at a local Markdown file — open it as a document pane.
        case document(URL)
        /// Any other URL — route through the external URL classifier / NSWorkspace.
        case external(URL)
    }

    /// Classify `url` into a `.document` or `.external` route.
    ///
    /// Delegates the local-markdown check entirely to `MarkdownLinkIntercept` so the
    /// same codepoint-safety fence that guards OSC 8 terminal links applies here too.
    /// Remote Md→Md links may use `awesomux-remote-md:` for `~/…` paths that must
    /// not be confused with the local filesystem.
    static func route(_ url: URL) -> Route {
        if url.scheme?.lowercased() == RemoteMarkdownReference.remoteMarkdownLinkScheme {
            return .document(url)
        }
        if let documentURL = MarkdownLinkIntercept.documentURL(forFileURL: url) {
            return .document(documentURL)
        }
        return .external(url)
    }
}
