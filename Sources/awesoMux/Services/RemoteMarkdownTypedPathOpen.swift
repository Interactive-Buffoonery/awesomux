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
    /// the remote typed-path sheet. Prefer a selected remote snapshot tab's
    /// declared identity; otherwise an active SSH pane's plan target.
    static func context(for session: TerminalSession) -> Context {
        if let tab = session.layout.firstDocumentGroup?.selectedTab,
            let identity = tab.remoteResourceIdentity,
            let target = identity.remoteTarget
        {
            return .remote(
                target: target,
                associatedPaneID: tab.associatedTerminalPaneID ?? session.activePaneID
            )
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

    /// Interactive typed-path open. Mirrors OSC / Md→Md a11y: announce loading
    /// before the fetch, then announce the outcome via
    /// `RemoteMarkdownTabRefresh.apply(announceOutcome:)`.
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
