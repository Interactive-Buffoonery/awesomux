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
        let documentID: DocumentPane.ID
        let identity: ResourceIdentity
        let associatedTerminalPaneID: TerminalPane.ID?
    }

    /// Records the outcome, then opens or updates the matching document tab.
    ///
    /// - Parameter selectingTab: Live opens and footer Refresh pass `true`
    ///   (subject to the compose guard inside `openDocumentPane`) and heal a
    ///   dead terminal association so send/stage is not stuck disabled. Restore
    ///   re-fetch passes `false` so a late SSH round-trip cannot steal selection
    ///   or capture whichever pane is active at launch.
    /// - Parameter announceOutcome: When true (footer Refresh), speak the
    ///   fetch result. Restore leaves this false so relaunch does not narrate
    ///   every remote tab.
    @MainActor
    static func apply(
        _ outcome: RemoteMarkdownFetchOutcome,
        in sessionID: TerminalSession.ID,
        associatedWith paneID: TerminalPane.ID?,
        sessionStore: SessionStore,
        selectingTab: Bool,
        announceOutcome: Bool = false
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
            // Footer Refresh / live open: heal a dead (restored-nil)
            // association. Restore re-fetch keeps `.preserveNil` so a
            // background tab cannot capture the launch-time active pane.
            associationPolicy: selectingTab ? .captureActivePaneWhenNil : .preserveNil,
            // `true` means "prefer select" — leave the compose-guard default
            // inside `openDocumentPane`. `false` is an explicit never-select
            // for restore re-fetch of background tabs.
            selectingNewTab: selectingTab ? nil : false
        )
        if announceOutcome {
            TerminalAccessibilityAnnouncer.announceRemoteMarkdown(outcome)
        }
    }

    /// Fetches one remote snapshot and applies the outcome when the tab is
    /// still present. Returns the outcome for tests; `nil` means the fetch was
    /// refused, the tab disappeared mid-flight, the cache/failure write failed,
    /// or another refresh for this tab is already in flight.
    ///
    /// - Parameter onFetchUnavailable: Called when `fetch` returns `nil` while
    ///   the tab is still open — the live OSC path's failure presentation.
    ///   Restore omits this so relaunch does not stack alerts; it still records
    ///   a refresh-failed policy note against the tab's current path.
    /// - Parameter coordinator: When provided, gates concurrent callers for the
    ///   same document id so a send-bar remount cannot start a second announce
    ///   path while the first SSH round trip is still finishing.
    @MainActor
    @discardableResult
    static func refresh(
        identity: ResourceIdentity,
        documentID: DocumentPane.ID,
        in sessionID: TerminalSession.ID,
        associatedWith paneID: TerminalPane.ID?,
        sessionStore: SessionStore,
        selectingTab: Bool,
        announceOutcome: Bool = false,
        coordinator: RemoteMarkdownRefreshCoordinator? = nil,
        onFetchUnavailable: (@MainActor () -> Void)? = nil,
        fetch: @MainActor (RemoteMarkdownReference) async -> RemoteMarkdownFetchOutcome? = {
            await RemoteMarkdownSnapshotFetcher().fetch($0)
        }
    ) async -> RemoteMarkdownFetchOutcome? {
        // A cancelled sweep must neither claim the coordinator latch nor
        // record a failure it never attempted.
        guard !Task.isCancelled else { return nil }
        if let coordinator, !coordinator.begin(documentID: documentID) {
            return nil
        }
        defer { coordinator?.finish(documentID: documentID) }

        guard let reference = RemoteMarkdownReference.make(identity: identity) else {
            return nil
        }
        guard
            sessionStore.session(id: sessionID)?.layout.firstDocumentGroup?
                .tab(id: documentID) != nil
        else {
            return nil
        }
        guard let outcome = await fetch(reference) else {
            // A nil outcome is a failed attempt (typically a cache/failure-page
            // write miss), not success. Note the policy against the tab's
            // current path so the stale banner can say so, and optionally
            // present the same alert the live OSC path uses.
            guard
                let tab = sessionStore.session(id: sessionID)?.layout.firstDocumentGroup?
                    .tab(id: documentID)
            else {
                return nil
            }
            let path = tab.fileURL.standardizedFileURL.path
            RemoteSnapshotStalePolicy.note(.remoteRefreshFailed, path: path)
            onFetchUnavailable?()
            if announceOutcome {
                TerminalAccessibilityAnnouncer.announceRemoteMarkdownRefreshUnavailable()
            }
            return nil
        }
        // Dropped while the fetch was in flight (a superseded restore sweep):
        // stay silent rather than noting a failure nobody caused or presenting
        // an alert for a tab nobody is waiting on.
        guard !Task.isCancelled else { return nil }
        // A closed tab must not be resurrected by a late fetch — same contract
        // as branch-changes Refresh carrying its originating document id.
        guard
            sessionStore.session(id: sessionID)?.layout.firstDocumentGroup?
                .tab(id: documentID) != nil
        else {
            return nil
        }
        apply(
            outcome,
            in: sessionID,
            associatedWith: paneID,
            sessionStore: sessionStore,
            selectingTab: selectingTab,
            announceOutcome: announceOutcome
        )
        return outcome
    }

    /// Walks the restored store and kicks a non-blocking fetch per remote
    /// Markdown tab. Tabs already mounted from cache; this updates them in
    /// place and re-establishes any stale banner from a real attempt.
    ///
    /// At most `maxConcurrentRestoreRefreshes` round trips are in flight at
    /// once, and fetches for one SSH target still serialize inside
    /// `RemoteMarkdownFetchCoordinator` — so N remote tabs cost ~8s×N/hosts
    /// wall-clock in the worst case rather than an SSH storm.
    ///
    /// Maximum simultaneous restore re-fetches. The fetch coordinator already
    /// serializes per SSH target, so this bounds host-parallelism: enough to
    /// keep several hosts busy, small enough to avoid an SSH storm at launch.
    private static let maxConcurrentRestoreRefreshes = 4

    @MainActor
    static func scheduleRestoreRefresh(
        for store: SessionStore,
        coordinator: RemoteMarkdownRefreshCoordinator? = nil,
        fetch: @escaping @MainActor (RemoteMarkdownReference) async -> RemoteMarkdownFetchOutcome? = {
            await RemoteMarkdownSnapshotFetcher().fetch($0)
        }
    ) {
        let targets = restoreTargets(in: store)
        guard !targets.isEmpty else { return }
        Task { @MainActor in
            // Bounded drain: awaiting the oldest running refresh before
            // starting past the limit keeps at most `maxConcurrentRestoreRefreshes`
            // in flight without a task group (whose Sendable closure could not
            // capture the session store).
            var running: [Task<RemoteMarkdownFetchOutcome?, Never>] = []
            var index = targets.startIndex
            while index != targets.endIndex, !Task.isCancelled {
                if running.count >= maxConcurrentRestoreRefreshes {
                    _ = await running.removeFirst().value
                }
                let target = targets[index]
                targets.formIndex(after: &index)
                running.append(
                    Task { @MainActor in
                        await refresh(
                            identity: target.identity,
                            documentID: target.documentID,
                            in: target.sessionID,
                            associatedWith: target.associatedTerminalPaneID,
                            sessionStore: store,
                            selectingTab: false,
                            announceOutcome: false,
                            coordinator: coordinator,
                            fetch: fetch
                        )
                    }
                )
            }
            for task in running {
                _ = await task.value
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
                            documentID: tab.id,
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
