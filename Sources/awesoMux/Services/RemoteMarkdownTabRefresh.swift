import AwesoMuxCore
import SwiftUI

/// Shared apply path for remote Markdown fetch outcomes.
///
/// Live link opens, restore re-fetch, and the document-tab Refresh button all
/// funnel here so they cannot drift: record through
/// `RemoteSnapshotStalePolicy`, then open/update the document tab the same way
/// the live path always has.
enum RemoteMarkdownTabRefresh {
    struct RestoreTarget: Equatable, Sendable {
        let sessionID: TerminalSession.ID
        let identity: ResourceIdentity
        let associatedTerminalPaneID: TerminalPane.ID?
    }

    /// Records the outcome, then opens or updates the matching document tab.
    ///
    /// - Parameter selectingTab: Live opens pass `true` (subject to the compose
    ///   guard inside `openDocumentPane`). Restore re-fetch passes `false` so a
    ///   late SSH round-trip cannot steal selection from another tab.
    @MainActor
    static func apply(
        _ outcome: RemoteMarkdownFetchOutcome,
        in sessionID: TerminalSession.ID,
        associatedWith paneID: TerminalPane.ID?,
        sessionStore: SessionStore,
        selectingTab: Bool
    ) {
        // Before opening: `DocumentPaneView` seeds its banner state at init, so
        // a note recorded afterwards would not be seen until the next remount.
        // The same order matters for an in-place refresh whose fileURL does not
        // change — the notification must land while the view is already up.
        RemoteSnapshotStalePolicy.record(outcome)
        let snapshot = outcome.snapshot
        sessionStore.openDocumentPane(
            fileURL: snapshot.fileURL,
            in: sessionID,
            associatedWith: paneID,
            remoteResourceIdentity: snapshot.identity,
            associationPolicy: .preserveNil,
            // `true` means "prefer select" — leave the compose-guard default
            // inside `openDocumentPane`. `false` is an explicit never-select
            // for restore re-fetch of background tabs.
            selectingNewTab: selectingTab ? nil : false
        )
    }

    /// Fetches one remote snapshot and applies the outcome when the tab is
    /// still present. Returns the outcome for tests; `nil` means the fetch was
    /// refused or the tab disappeared mid-flight.
    @MainActor
    @discardableResult
    static func refresh(
        identity: ResourceIdentity,
        in sessionID: TerminalSession.ID,
        associatedWith paneID: TerminalPane.ID?,
        sessionStore: SessionStore,
        selectingTab: Bool,
        fetch: @MainActor (RemoteMarkdownReference) async -> RemoteMarkdownFetchOutcome? = {
            await RemoteMarkdownSnapshotFetcher().fetch($0)
        }
    ) async -> RemoteMarkdownFetchOutcome? {
        guard let reference = RemoteMarkdownReference.make(identity: identity) else {
            return nil
        }
        guard
            sessionStore.session(id: sessionID)?.layout.firstDocumentGroup?
                .tab(forRemoteResource: identity) != nil
        else {
            return nil
        }
        guard let outcome = await fetch(reference) else {
            return nil
        }
        // A closed tab must not be resurrected by a late fetch — same contract
        // as branch-changes Refresh carrying its originating document id.
        guard
            sessionStore.session(id: sessionID)?.layout.firstDocumentGroup?
                .tab(forRemoteResource: identity) != nil
        else {
            return nil
        }
        apply(
            outcome,
            in: sessionID,
            associatedWith: paneID,
            sessionStore: sessionStore,
            selectingTab: selectingTab
        )
        return outcome
    }

    /// Walks the restored store and kicks a non-blocking fetch per remote
    /// Markdown tab. Tabs already mounted from cache; this updates them in
    /// place and re-establishes any stale banner from a real attempt.
    @MainActor
    static func scheduleRestoreRefresh(
        for store: SessionStore,
        fetch: @escaping @MainActor (RemoteMarkdownReference) async -> RemoteMarkdownFetchOutcome? = {
            await RemoteMarkdownSnapshotFetcher().fetch($0)
        }
    ) {
        for target in restoreTargets(in: store) {
            Task { @MainActor in
                _ = await refresh(
                    identity: target.identity,
                    in: target.sessionID,
                    associatedWith: target.associatedTerminalPaneID,
                    sessionStore: store,
                    selectingTab: false,
                    fetch: fetch
                )
            }
        }
    }

    /// Pure enumeration of restore work — tests assert the walk without
    /// scheduling Tasks.
    @MainActor
    static func restoreTargets(in store: SessionStore) -> [RestoreTarget] {
        var targets: [RestoreTarget] = []
        for group in store.groups {
            for session in group.sessions {
                guard let documentGroup = session.layout.firstDocumentGroup else {
                    continue
                }
                for tab in documentGroup.tabs {
                    guard let identity = tab.remoteResourceIdentity,
                        identity.isSupportedRemoteMarkdownSnapshot
                    else {
                        continue
                    }
                    targets.append(
                        RestoreTarget(
                            sessionID: session.id,
                            identity: identity,
                            associatedTerminalPaneID: tab.associatedTerminalPaneID
                        )
                    )
                }
            }
        }
        return targets
    }
}

/// The app's remote Markdown Refresh command, addressed by session + document
/// tab so the send bar can refresh the tab it is drawn on.
///
/// Delivered through the environment for the same reason as
/// `BranchChangesRefreshAction`: the fetch needs the session store, and the
/// send bar should not hold a global to reach it.
struct RemoteMarkdownRefreshAction {
    let run:
        @MainActor (
            _ sessionID: TerminalSession.ID,
            _ documentID: DocumentPane.ID,
            _ completion: @escaping @MainActor () -> Void
        ) -> Void
}

extension EnvironmentValues {
    @Entry var remoteMarkdownRefresh: RemoteMarkdownRefreshAction?
}
