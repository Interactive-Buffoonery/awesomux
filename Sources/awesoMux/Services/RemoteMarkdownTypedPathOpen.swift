import AwesoMuxCore
import Foundation

/// Opens a remote Markdown file from a typed absolute/`~/` path when the
/// focused context is an SSH pane or a remote snapshot tab.
///
/// V0 is typed-path only — no directory listing or View Files browse. The
/// declared `RemoteTarget` (plan or tab identity) authorizes the fetch; title
/// host never does.
enum RemoteMarkdownTypedPathOpen {
    struct PreparedOpen {
        let reference: RemoteMarkdownReference
        let attempt: RemoteMarkdownFetchCoordinator.PreparedAttempt
        let progressClaim: RemoteMarkdownFetchProgressCoordinator.Claim
    }

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
    ///
    /// Capture this at sheet submit — do not re-read live selection after dismiss.
    static func fetchProgressOrigin(
        for session: TerminalSession
    ) -> RemoteMarkdownFetchProgressCoordinator.Origin {
        let resolved = context(for: session)
        if case .remote(let target, _) = resolved,
            let tabTarget = session.layout.firstDocumentGroup?.selectedTab?
                .remoteResourceIdentity?.remoteTarget,
            tabTarget == target
        {
            return .document
        }
        if case .remote(_, let paneID) = resolved, let paneID {
            return .surface(paneID: paneID)
        }
        return .document
    }

    /// Source-tab pin for document-origin chrome. Frozen at submit with origin.
    static func overlayIdentity(for session: TerminalSession) -> ResourceIdentity? {
        session.layout.firstDocumentGroup?.selectedTab?.remoteResourceIdentity
    }

    /// Sheet-submit prelude: validate, **begin** the waiter (first-waiter +
    /// chrome reserved), announce loading immediately only when that begin
    /// returned first-waiter, then the caller dismisses and `open` adopts the
    /// claim. Returns `nil` when the path fails closed before begin.
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
        sessionID: TerminalSession.ID,
        origin: RemoteMarkdownFetchProgressCoordinator.Origin,
        overlayIdentity: ResourceIdentity? = nil,
        progress: RemoteMarkdownFetchProgressCoordinator = .shared,
        onAnnounceLoading: @MainActor () -> Void = {
            TerminalAccessibilityAnnouncer.announceRemoteMarkdownLoadingImmediately()
        },
        onRoutingFailure: @MainActor () -> Void = {
            GhosttyRuntime.remoteMarkdownRoutingFailurePresenter(nil)
        }
    ) -> RemoteMarkdownFetchProgressCoordinator.Claim? {
        guard let reference = reference(typedPath: typedPath, target: target) else {
            onRoutingFailure()
            return nil
        }
        let claim = progress.beginClaim(
            sessionID: sessionID,
            identity: reference.identity,
            origin: origin,
            overlayIdentity: overlayIdentity
        )
        if claim.isFirstWaiter {
            onAnnounceLoading()
        }
        return claim
    }

    /// Production sheet-submit path. Register the fetch cohort before the
    /// immediate loading cue so every entry point agrees on one speech owner.
    @MainActor
    static func prepareLoadingIfValid(
        typedPath: String,
        target: RemoteTarget,
        sessionID: TerminalSession.ID,
        origin: RemoteMarkdownFetchProgressCoordinator.Origin,
        overlayIdentity: ResourceIdentity? = nil,
        progress: RemoteMarkdownFetchProgressCoordinator = .shared,
        onAnnounceLoading: @MainActor () -> Void = {
            TerminalAccessibilityAnnouncer.announceRemoteMarkdownLoadingImmediately()
        },
        onRoutingFailure: @MainActor () -> Void = {
            GhosttyRuntime.remoteMarkdownRoutingFailurePresenter(nil)
        }
    ) -> PreparedOpen? {
        guard let reference = reference(typedPath: typedPath, target: target) else {
            onRoutingFailure()
            return nil
        }
        let attempt = RemoteMarkdownSnapshotFetcher().startAttempt(reference, consumer: .other)
        let claim = progress.beginClaim(
            sessionID: sessionID,
            identity: reference.identity,
            origin: origin,
            overlayIdentity: overlayIdentity
        )
        if attempt.ownsAnnouncements {
            onAnnounceLoading()
        }
        return PreparedOpen(reference: reference, attempt: attempt, progressClaim: claim)
    }

    /// Interactive typed-path open. Mirrors OSC / Md→Md a11y for non-sheet
    /// callers (async loading hop via `announceRemoteMarkdownLoading`). Sheet
    /// submit must call `announceLoadingIfValid` first (begin + immediate post
    /// while the sheet is up), dismiss, then pass that `progressClaim` here so
    /// this path does not begin a second waiter. `origin` is the frozen
    /// submit-time chrome host — never re-read from live selection after dismiss
    /// when a claim is already adopted.
    ///
    /// Loading and outcome announcements are first-waiter-only, matching OSC /
    /// recent-link. Closures (not flags) let tests observe order without posting
    /// through the global announcer that parallel suites share.
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
        overlayIdentity: ResourceIdentity? = nil,
        progressClaim: RemoteMarkdownFetchProgressCoordinator.Claim? = nil,
        preparedOpen: PreparedOpen? = nil,
        progress: RemoteMarkdownFetchProgressCoordinator = .shared
    ) async -> DocumentPane.ID? {
        guard let reference = preparedOpen?.reference ?? reference(typedPath: typedPath, target: target) else {
            if let progressClaim {
                progress.finish(progressClaim)
            }
            onRoutingFailure()
            return nil
        }
        let claim: RemoteMarkdownFetchProgressCoordinator.Claim
        if let preparedOpen {
            claim = preparedOpen.progressClaim
        } else if let progressClaim {
            claim = progressClaim
        } else {
            let resolvedOrigin =
                origin
                ?? sessionStore.session(id: sessionID).map(fetchProgressOrigin(for:))
                ?? .document
            let resolvedOverlay: ResourceIdentity?
            if let overlayIdentity {
                resolvedOverlay = overlayIdentity
            } else if case .document = resolvedOrigin {
                resolvedOverlay = sessionStore.session(id: sessionID).flatMap(
                    Self.overlayIdentity(for:)
                )
            } else {
                resolvedOverlay = nil
            }
            claim = progress.beginClaim(
                sessionID: sessionID,
                identity: reference.identity,
                origin: resolvedOrigin,
                overlayIdentity: resolvedOverlay
            )
            if claim.isFirstWaiter {
                onAnnounceLoading()
            }
        }
        defer { progress.finish(claim) }
        let outcome =
            if let preparedOpen {
                await preparedOpen.attempt.value().outcome
            } else {
                await fetch(reference)
            }
        guard let outcome else {
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
        if preparedOpen?.attempt.ownsAnnouncements ?? claim.isFirstWaiter {
            onAnnounceOutcome(outcome)
        }
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
