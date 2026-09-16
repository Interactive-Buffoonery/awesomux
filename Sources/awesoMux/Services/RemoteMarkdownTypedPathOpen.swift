import AwesoMuxCore
import Foundation

/// Opens a remote Markdown file from a typed absolute/`~/` path when the
/// focused context is an SSH pane or a remote snapshot tab.
///
/// V0 is typed-path only — no directory listing or View Files browse. The
/// declared `RemoteTarget` (plan or tab identity) authorizes the fetch; title
/// host never does.
enum RemoteMarkdownTypedPathOpen {
    enum Context: Equatable, Sendable {
        case local
        case remote(target: RemoteTarget, associatedPaneID: TerminalPane.ID?)
    }

    /// Resolves whether ⌘O / Open Markdown should use the local open panel or
    /// the remote typed-path sheet.
    ///
    /// Order: selected **non-remote** document tab → local (even when the
    /// active pane is SSH); selected remote snapshot tab → remote, unless the
    /// active SSH pane names a *different* host (then that pane wins, so a
    /// leftover tab for host A cannot fetch from A while focus is on B); else
    /// active SSH pane → remote; else local.
    static func context(for session: TerminalSession) -> Context {
        let activeSSHContext: Context? = {
            guard let pane = session.activePane,
                case .ssh(let execution) = pane.executionPlan
            else { return nil }
            return .remote(target: execution.target, associatedPaneID: pane.id)
        }()

        if let tab = session.layout.firstDocumentGroup?.selectedTab {
            if let identity = tab.remoteResourceIdentity,
                let tabTarget = identity.remoteTarget
            {
                if case .remote(let sshTarget, let paneID)? = activeSSHContext,
                    sshTarget != tabTarget
                {
                    return .remote(target: sshTarget, associatedPaneID: paneID)
                }
                return .remote(
                    target: tabTarget,
                    associatedPaneID: tab.associatedTerminalPaneID ?? session.activePaneID
                )
            }
            // A focused local (or generated) document tab keeps ⌘O on the Mac
            // open panel — do not let a sibling SSH pane steal it.
            return .local
        }
        return activeSSHContext ?? .local
    }

    /// Pure reference construction for tests and the sheet submit path. Fail
    /// closed on relative paths, escapes above `~/`, unsupported extensions,
    /// and unsafe scalars — same normalize helpers as Md→Md click gates.
    static func reference(
        typedPath: String,
        target: RemoteTarget
    ) -> RemoteMarkdownReference? {
        RemoteMarkdownReference.make(typedPath: typedPath, target: target)
    }

    /// Resolves progress chrome for a typed-path open: snapshot tabs keep the
    /// document overlay; an SSH pane with no remote tab uses the surface spinner.
    static func fetchProgressOrigin(
        for session: TerminalSession
    ) -> RemoteMarkdownFetchProgressCoordinator.Origin {
        if session.layout.firstDocumentGroup?.selectedTab?.remoteResourceIdentity != nil {
            return .document
        }
        if case .remote(_, let paneID) = context(for: session), let paneID {
            return .surface(paneID: paneID)
        }
        return .document
    }

    /// Sheet-submit prelude: validate, announce loading **immediately** for the
    /// first waiter (sheet still up), then the caller dismisses and fetches.
    /// Returns false when the path fails closed before announce.
    ///
    /// Uses `announceRemoteMarkdownLoadingImmediately` rather than the async
    /// hop in `announceRemoteMarkdownLoading` — dismiss starts on this turn, and
    /// a deferred AX post can lose or reorder the cue during sheet teardown.
    /// Coalesced waiters stay silent, matching OSC first-waiter-only speech.
    @MainActor
    @discardableResult
    static func announceLoadingIfValid(
        typedPath: String,
        target: RemoteTarget,
        sessionID: TerminalSession.ID? = nil,
        progress: RemoteMarkdownFetchProgressCoordinator? = nil,
        onAnnounceLoading: @MainActor () -> Void = {
            TerminalAccessibilityAnnouncer.announceRemoteMarkdownLoadingImmediately()
        },
        onRoutingFailure: @MainActor () -> Void = {
            GhosttyRuntime.remoteMarkdownRoutingFailurePresenter(nil)
        }
    ) -> Bool {
        guard let reference = reference(typedPath: typedPath, target: target) else {
            onRoutingFailure()
            return false
        }
        if let sessionID, let progress,
            progress.isInFlight(sessionID: sessionID, identity: reference.identity)
        {
            return true
        }
        onAnnounceLoading()
        return true
    }

    /// Interactive typed-path open. Mirrors OSC / Md→Md a11y for non-sheet
    /// callers (async loading hop via `announceRemoteMarkdownLoading`). Sheet
    /// submit should call `announceLoadingIfValid` first (immediate post while
    /// the sheet is up), dismiss, then pass `onAnnounceLoading: {}` here.
    ///
    /// The outcome announcement is a closure (not a flag) like the loading
    /// one, so tests can observe the full loading→fetch→outcome order without
    /// posting through the global announcer that parallel suites share.
    @MainActor
    @discardableResult
    static func open(
        typedPath: String,
        target: RemoteTarget,
        in sessionID: TerminalSession.ID,
        associatedWith paneID: TerminalPane.ID?,
        sessionStore: SessionStore,
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
        onAnnounceOutcome: @MainActor (RemoteMarkdownFetchOutcome) -> Void = {
            TerminalAccessibilityAnnouncer.announceRemoteMarkdown($0)
        },
        origin: RemoteMarkdownFetchProgressCoordinator.Origin? = nil,
        progress: RemoteMarkdownFetchProgressCoordinator = .shared
    ) async -> DocumentPane.ID? {
        guard let reference = reference(typedPath: typedPath, target: target) else {
            onRoutingFailure()
            return nil
        }
        let resolvedOrigin =
            origin
            ?? sessionStore.session(id: sessionID).map(fetchProgressOrigin(for:))
            ?? .document
        let isFirstWaiter = progress.begin(
            sessionID: sessionID,
            identity: reference.identity,
            origin: resolvedOrigin
        )
        if isFirstWaiter {
            onAnnounceLoading()
        }
        defer {
            progress.finish(
                sessionID: sessionID,
                identity: reference.identity,
                origin: resolvedOrigin
            )
        }
        guard let outcome = await fetch(reference) else {
            onFetchFailure()
            return nil
        }
        // Sheet dismiss already happened; the associated SSH pane can reconnect
        // or repoint during the round trip. Applying host-A bytes onto a pane
        // that now names host B would attach the snapshot to the wrong context.
        guard
            associatedContextStillMatches(
                capturedTarget: target,
                in: sessionID,
                associatedWith: paneID,
                sessionStore: sessionStore
            )
        else {
            return nil
        }
        guard
            let openedID = RemoteMarkdownTabRefresh.apply(
                outcome,
                in: sessionID,
                associatedWith: paneID,
                sessionStore: sessionStore,
                selectingTab: true,
                announceOutcome: false
            )
        else {
            // Fetch succeeded but the tab did not open (session gone, etc.).
            // Stay silent like the OSC stale-dispatch path and the Md→Md open:
            // the path was trusted and the fetch worked, so the routing-failure
            // alert would name the wrong failure, and there is nothing on screen
            // to explain.
            return nil
        }
        onAnnounceOutcome(outcome)
        return openedID
    }

    /// After a fetch, refuse apply when the originating session/pane is gone or
    /// the associated SSH pane now names a different host than the one we
    /// fetched from. A local associated pane is not a conflicting host.
    @MainActor
    static func associatedContextStillMatches(
        capturedTarget: RemoteTarget,
        in sessionID: TerminalSession.ID,
        associatedWith paneID: TerminalPane.ID?,
        sessionStore: SessionStore
    ) -> Bool {
        guard let session = sessionStore.session(id: sessionID) else {
            return false
        }
        guard let paneID else {
            return true
        }
        guard let pane = session.layout.pane(id: paneID) else {
            return false
        }
        if let liveTarget = pane.executionPlan.remoteTarget {
            return liveTarget == capturedTarget
        }
        return true
    }
}

/// Remembers the last submitted typed path per SSH destination so a reopened
/// sheet — typically after a failed fetch — starts from the previous attempt
/// instead of an empty field. Paths only, never file contents.
struct RemoteMarkdownTypedPathHistory: Sendable, Equatable {
    private var lastPaths: [RemoteTarget: String] = [:]

    mutating func remember(_ path: String, for target: RemoteTarget) {
        lastPaths[target] = path
    }

    func lastPath(for target: RemoteTarget) -> String? {
        lastPaths[target]
    }
}
