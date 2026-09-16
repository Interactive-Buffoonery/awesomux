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
    /// Order: selected remote snapshot tab → remote; selected **non-remote**
    /// document tab → local (even when the active pane is SSH); else active
    /// SSH pane → remote; else local.
    static func context(for session: TerminalSession) -> Context {
        if let tab = session.layout.firstDocumentGroup?.selectedTab {
            if let identity = tab.remoteResourceIdentity,
                let target = identity.remoteTarget
            {
                return .remote(
                    target: target,
                    associatedPaneID: tab.associatedTerminalPaneID ?? session.activePaneID
                )
            }
            // A focused local (or generated) document tab keeps ⌘O on the Mac
            // open panel — do not let a sibling SSH pane steal it.
            return .local
        }
        if let pane = session.activePane,
            case .ssh(let execution) = pane.executionPlan
        {
            return .remote(target: execution.target, associatedPaneID: pane.id)
        }
        return .local
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

    /// Sheet-submit prelude: validate, announce loading **immediately** (sheet
    /// still up), then the caller dismisses and fetches. Returns false when the
    /// path fails closed before announce.
    ///
    /// Uses `announceRemoteMarkdownLoadingImmediately` rather than the async
    /// hop in `announceRemoteMarkdownLoading` — dismiss starts on this turn, and
    /// a deferred AX post can lose or reorder the cue during sheet teardown.
    @MainActor
    @discardableResult
    static func announceLoadingIfValid(
        typedPath: String,
        target: RemoteTarget,
        onAnnounceLoading: @MainActor () -> Void = {
            TerminalAccessibilityAnnouncer.announceRemoteMarkdownLoadingImmediately()
        },
        onRoutingFailure: @MainActor () -> Void = {
            GhosttyRuntime.remoteMarkdownRoutingFailurePresenter(nil)
        }
    ) -> Bool {
        guard reference(typedPath: typedPath, target: target) != nil else {
            onRoutingFailure()
            return false
        }
        onAnnounceLoading()
        return true
    }

    /// Interactive typed-path open. Mirrors OSC / Md→Md a11y for non-sheet
    /// callers (async loading hop via `announceRemoteMarkdownLoading`). Sheet
    /// submit should call `announceLoadingIfValid` first (immediate post while
    /// the sheet is up), dismiss, then pass `onAnnounceLoading: {}` here.
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
        onAnnounceLoading: @MainActor () -> Void = {
            TerminalAccessibilityAnnouncer.announceRemoteMarkdownLoading()
        }
    ) async -> DocumentPane.ID? {
        guard let reference = reference(typedPath: typedPath, target: target) else {
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
