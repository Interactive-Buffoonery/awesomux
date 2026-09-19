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

    /// Interactive Md→Md open. Mirrors OSC remote-open a11y: first-waiter
    /// loading speech and first-waiter outcome via
    /// `RemoteMarkdownTabRefresh.apply(announceOutcome:)`. Routing failures keep
    /// the existing alert presenter. Progress chrome is identity-keyed document
    /// overlay on the source pin plus fetch identity — never a provisional
    /// `DocumentPane`.
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
        startAttempt: (@MainActor (RemoteMarkdownReference) -> RemoteMarkdownFetchCoordinator.PreparedAttempt)? = nil,
        fetch: (@MainActor (RemoteMarkdownReference) async -> RemoteMarkdownFetchOutcome?)? = nil,
        onRoutingFailure: @MainActor () -> Void = {
            GhosttyRuntime.remoteMarkdownRoutingFailurePresenter(nil)
        },
        onFetchFailure: @MainActor () -> Void = {
            GhosttyRuntime.remoteMarkdownFetchFailurePresenter(nil)
        },
        onAnnounceLoading: @MainActor () -> Void = {
            TerminalAccessibilityAnnouncer.announceRemoteMarkdownLoading()
        },
        onAnnounceOutcome: @MainActor (RemoteMarkdownFetchOutcome) -> Void = {
            TerminalAccessibilityAnnouncer.announceRemoteMarkdown($0)
        },
        onAnnounceFragmentOpened: @MainActor () -> Void = {
            TerminalAccessibilityAnnouncer.announceRemoteMarkdownOpenedAtTop()
        },
        progress: RemoteMarkdownFetchProgressCoordinator = .shared
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
        let prepared: RemoteMarkdownFetchCoordinator.PreparedAttempt
        if let startAttempt {
            prepared = startAttempt(reference)
        } else if let fetch {
            let cohort = RemoteMarkdownFetchCoordinator.Cohort()
            cohort.add(.document)
            prepared = .init(
                cohort: cohort,
                ownsAnnouncements: true,
                task: Task { await fetch(reference) },
                isNew: true,
                onCoalesced: nil,
                onRegistered: nil,
                onFinished: nil
            )
        } else {
            prepared = RemoteMarkdownSnapshotFetcher().startAttempt(
                reference,
                consumer: .document
            )
        }
        let origin = RemoteMarkdownFetchProgressCoordinator.Origin.document
        _ = progress.begin(
            sessionID: sessionID,
            identity: reference.identity,
            origin: origin,
            overlayIdentity: source
        )
        let isFirstWaiter = prepared.ownsAnnouncements
        if isFirstWaiter {
            onAnnounceLoading()
        }
        defer {
            progress.finish(
                sessionID: sessionID,
                identity: reference.identity,
                origin: origin,
                overlayIdentity: source
            )
        }
        let attempt = await prepared.value()
        guard let outcome = attempt.outcome else {
            guard sessionStore.session(id: sessionID) != nil else {
                return nil
            }
            // The sheet is both the sighted failure state and VoiceOver's
            // result cue. Refresh/restore owners defer to it when a document
            // waiter joined, so presenting it here does not double-speak.
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
            announceOutcome: false
        )
        if isFirstWaiter, openedID != nil {
            onAnnounceOutcome(outcome)
        }
        // Only announce the at-top landing for a fresh snapshot on a newly
        // mounted tab. Stale cache and failure pages still open a tab but
        // contradict the cue; a session gone mid-fetch returns nil from apply.
        if isFirstWaiter,
            openedID != nil,
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
