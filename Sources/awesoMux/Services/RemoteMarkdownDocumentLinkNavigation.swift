import AwesoMuxCore
import Foundation

/// Opens a Markdown→Markdown link from a remote snapshot tab as another remote
/// snapshot, reusing the declared `ResourceIdentity` location (never the title
/// host or local cache path).
enum RemoteMarkdownDocumentLinkNavigation {
    /// Pure reference construction for tests and the click sink. Fail closed on
    /// missing identity support, paths outside the source document directory,
    /// or URLs that are not remote-resolved document links.
    static func reference(
        forOpenedLinkURL url: URL,
        from source: ResourceIdentity
    ) -> RemoteMarkdownReference? {
        RemoteMarkdownReference.make(openedLinkURL: url, relativeTo: source)
    }

    /// Interactive Md→Md open. Mirrors OSC remote-open a11y: announce loading
    /// before the fetch, then announce the outcome via
    /// `RemoteMarkdownTabRefresh.apply(announceOutcome:)`. Routing failures keep
    /// the existing alert presenter. Progress spinners stay on the OSC surface
    /// path where a `GhosttySurfaceNSView` host exists.
    @MainActor
    @discardableResult
    static func open(
        url: URL,
        from source: ResourceIdentity,
        in sessionID: TerminalSession.ID,
        associatedWith paneID: TerminalPane.ID?,
        sessionStore: SessionStore,
        fetch: @MainActor (RemoteMarkdownReference) async -> RemoteMarkdownFetchOutcome? = {
            await RemoteMarkdownSnapshotFetcher().fetch($0)
        },
        onRoutingFailure: @MainActor () -> Void = {
            GhosttyRuntime.remoteMarkdownRoutingFailurePresenter(nil)
        },
        onAnnounceLoading: @MainActor () -> Void = {
            TerminalAccessibilityAnnouncer.announceRemoteMarkdownLoading()
        }
    ) async -> DocumentPane.ID? {
        guard let reference = reference(forOpenedLinkURL: url, from: source) else {
            onRoutingFailure()
            return nil
        }
        onAnnounceLoading()
        guard let outcome = await fetch(reference) else {
            onRoutingFailure()
            return nil
        }
        return RemoteMarkdownTabRefresh.apply(
            outcome,
            in: sessionID,
            associatedWith: paneID,
            sessionStore: sessionStore,
            selectingTab: true,
            announceOutcome: true
        )
    }
}
