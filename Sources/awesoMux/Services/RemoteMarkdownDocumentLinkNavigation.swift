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
    ///
    /// A destination that carries a `#fragment` opens at the top only when it
    /// mounts a *new* tab — fragment scroll is deferred — and says so through
    /// `onAnnounceFragmentOpened`. An already-open target is left where it is
    /// and stays silent, because nothing moved.
    @MainActor
    @discardableResult
    static func open(
        url: URL,
        from source: ResourceIdentity,
        in sessionID: TerminalSession.ID,
        associatedWith paneID: TerminalPane.ID?,
        sessionStore: SessionStore,
        coordinator: RemoteMarkdownDocumentLinkCoordinator? = .shared,
        fetch: @MainActor (RemoteMarkdownReference) async -> RemoteMarkdownFetchOutcome? = {
            await RemoteMarkdownSnapshotFetcher().fetch($0)
        },
        onRoutingFailure: @MainActor () -> Void = {
            GhosttyRuntime.remoteMarkdownRoutingFailurePresenter(nil)
        },
        onFetchFailure: @MainActor () -> Void = {
            GhosttyRuntime.remoteMarkdownFetchFailurePresenter(nil)
        },
        onAnnounceLoading: @MainActor () -> Void = {
            TerminalAccessibilityAnnouncer.announceRemoteMarkdownLoading()
        },
        onAnnounceFragmentOpened: @MainActor () -> Void = {
            TerminalAccessibilityAnnouncer.announceRemoteMarkdownOpenedAtTop()
        }
    ) async -> DocumentPane.ID? {
        guard let reference = reference(forOpenedLinkURL: url, from: source) else {
            onRoutingFailure()
            return nil
        }
        // Drop a re-click for a file that is already opening: the fetch layer
        // would coalesce the network work, but this second caller would still
        // load-announce, apply, and outcome-announce again.
        if let coordinator, !coordinator.begin(sessionID: sessionID, identity: reference.identity) {
            return nil
        }
        defer { coordinator?.finish(sessionID: sessionID, identity: reference.identity) }
        onAnnounceLoading()
        guard let outcome = await fetch(reference) else {
            onFetchFailure()
            return nil
        }
        // A fragment link lands at the top only when it mounts a *new* tab. An
        // already-open target either stays where it is (a self-link) or reopens
        // at its saved reading position, so the at-top cue would be false.
        // Checked after the fetch so a tab opened or closed elsewhere during
        // the SSH round trip is not judged against a stale snapshot.
        let targetAlreadyOpen =
            sessionStore.session(id: sessionID)?.layout.firstDocumentGroup?
            .tab(forRemoteResource: reference.identity) != nil
        let openedID = RemoteMarkdownTabRefresh.apply(
            outcome,
            in: sessionID,
            associatedWith: paneID,
            sessionStore: sessionStore,
            selectingTab: true,
            announceOutcome: true
        )
        // Only announce the at-top landing for a fresh snapshot on a newly
        // mounted tab. Stale cache and failure pages still open a tab but
        // contradict the cue; a session gone mid-fetch returns nil from apply.
        if openedID != nil,
            !targetAlreadyOpen,
            case .fresh = outcome,
            let fragment = url.fragment,
            !fragment.isEmpty
        {
            onAnnounceFragmentOpened()
        }
        return openedID
    }
}
