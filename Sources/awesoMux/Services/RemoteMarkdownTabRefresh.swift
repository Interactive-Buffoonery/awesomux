import AwesoMuxCore
import SwiftUI

/// Shared apply path for remote Markdown fetch outcomes.
///
/// Live link opens, restore re-fetch, and the document-tab Refresh button all
/// funnel here so they cannot drift: record through
/// `RemoteSnapshotStalePolicy`, then open/update the document tab the same way
/// the live path always has.
enum RemoteMarkdownTabRefresh {
    static func fetchConsumer(
        announcesOutcome: Bool
    ) -> RemoteMarkdownFetchCoordinator.Cohort.Consumer {
        announcesOutcome ? .refresh : .restore
    }

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
    /// - Returns: The document tab id that received the snapshot, when open
    ///   succeeded — used by Md→Md navigation to request focus.
    @MainActor
    @discardableResult
    static func apply(
        _ outcome: RemoteMarkdownFetchOutcome,
        in sessionID: TerminalSession.ID,
        associatedWith paneID: TerminalPane.ID?,
        sessionStore: SessionStore,
        selectingTab: Bool,
        announceOutcome: Bool = false
    ) -> DocumentPane.ID? {
        // Before opening: `DocumentPaneView` seeds its banner state at init, so
        // a note recorded afterwards would not be seen until the next remount.
        // The same order matters for an in-place refresh whose fileURL does not
        // change — the notification must land while the view is already up.
        RemoteSnapshotStalePolicy.record(outcome)
        let snapshot = outcome.snapshot
        let openedID = sessionStore.openDocumentPane(
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
        // Speak the outcome only when a tab actually opened. A session torn
        // down mid-fetch returns nil, and a success cue with nothing on screen
        // misleads VoiceOver.
        if announceOutcome, openedID != nil {
            TerminalAccessibilityAnnouncer.announceRemoteMarkdown(outcome)
        }
        return openedID
    }

    /// Fetches one remote snapshot and applies the outcome when the tab is
    /// still present. Returns the outcome for tests; `nil` means the fetch was
    /// refused, the tab disappeared mid-flight, the cache/failure write failed,
    /// or another refresh for this tab is already in flight.
    ///
    /// - Parameter coordinator: When provided, gates concurrent callers for the
    ///   same document id so a send-bar remount cannot start a second announce
    ///   path while the first SSH round trip is still finishing.
    ///
    /// A `nil` fetch still records a refresh-failed policy note against the
    /// tab's current path (the stale banner) and speaks the unavailable outcome
    /// when `announceOutcome` (the send-bar Refresh, which also speaks success)
    /// or `announceFailure` (restore, which speaks only a failure for the tab
    /// the user is looking at) is set. No alert is presented: the banner and
    /// announcement already tell the whole story.
    ///
    /// - Parameter announceFailure: Speaks only the unavailable outcome, not
    ///   success. Restore uses it for the selected tab so a launch-time failure
    ///   over the visible document is announced, while background tabs stay
    ///   silent and a launch-time success is not narrated.
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
        announceFailure: Bool = false,
        coordinator: RemoteMarkdownRefreshCoordinator? = nil,
        progress: RemoteMarkdownFetchProgressCoordinator = .shared,
        onAnnounceLoading: @MainActor () -> Void = {
            TerminalAccessibilityAnnouncer.announceRemoteMarkdownLoading()
        },
        onAnnounceOutcome: @MainActor (RemoteMarkdownFetchOutcome) -> Void = {
            TerminalAccessibilityAnnouncer.announceRemoteMarkdown($0)
        },
        onAnnounceFailure: @MainActor () -> Void = {
            TerminalAccessibilityAnnouncer.announceRemoteMarkdownRefreshUnavailable()
        },
        startAttempt: (@MainActor (RemoteMarkdownReference) -> RemoteMarkdownFetchCoordinator.PreparedAttempt)? = nil,
        fetch: (@MainActor (RemoteMarkdownReference) async -> RemoteMarkdownFetchOutcome?)? = nil
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
        // Footer Refresh shares announcement ownership with link opens for the
        // same remote file. Keep the tab latch above as the stronger duplicate
        // guard for repeated Refresh clicks; this identity-keyed claim only
        // decides which otherwise-valid caller speaks.
        let consumer = fetchConsumer(announcesOutcome: announceOutcome)
        let prepared: RemoteMarkdownFetchCoordinator.PreparedAttempt
        if let startAttempt {
            prepared = startAttempt(reference)
        } else if let fetch {
            let cohort = RemoteMarkdownFetchCoordinator.Cohort()
            cohort.add(consumer)
            prepared = .init(
                cohort: cohort,
                ownsAnnouncements: consumer != .restore,
                task: Task { await fetch(reference) },
                isNew: true,
                onCoalesced: nil,
                onRegistered: nil,
                onFinished: nil
            )
        } else {
            prepared = RemoteMarkdownSnapshotFetcher().startAttempt(
                reference,
                consumer: consumer,
                announcementSessionID: sessionID
            )
        }
        let participatesInAnnouncementOwnership = announceOutcome || announceFailure
        let ownsAnnouncements: Bool
        if participatesInAnnouncementOwnership {
            _ = progress.begin(
                sessionID: sessionID,
                identity: identity,
                origin: announceOutcome ? .refresh : .restore
            )
            ownsAnnouncements = prepared.ownsAnnouncements
            if announceOutcome, ownsAnnouncements {
                onAnnounceLoading()
            }
        } else {
            ownsAnnouncements = true
        }
        defer {
            if participatesInAnnouncementOwnership {
                progress.finish(
                    sessionID: sessionID,
                    identity: identity,
                    origin: announceOutcome ? .refresh : .restore
                )
            }
        }
        let attempt = await prepared.value()
        let fetchedOutcome = attempt.outcome
        if Task.isCancelled {
            if let fetchedOutcome,
                announceOutcome,
                ownsAnnouncements,
                attempt.hasCoalescedInteractiveConsumer,
                sessionStore.session(id: sessionID) != nil
            {
                onAnnounceOutcome(fetchedOutcome)
            }
            return nil
        }
        guard let outcome = fetchedOutcome else {
            let ownsFailureAnnouncement =
                announceFailure
                ? !attempt.hasInteractiveConsumer
                : ownsAnnouncements
            // A nil outcome is a failed attempt (typically a cache/failure-page
            // write miss), not success. Note the policy against the tab's
            // current path so the stale banner can say so, and speak it for the
            // send-bar Refresh. No alert: the banner and announcement cover it.
            guard
                let tab = sessionStore.session(id: sessionID)?.layout.firstDocumentGroup?
                    .tab(id: documentID)
            else {
                if announceOutcome,
                    ownsFailureAnnouncement,
                    attempt.hasCoalescedInteractiveConsumer,
                    !attempt.hasFailurePresenter,
                    sessionStore.session(id: sessionID) != nil
                {
                    onAnnounceFailure()
                }
                return nil
            }
            let path = tab.fileURL.standardizedFileURL.path
            // A tab already on the app-generated failure page has no "last
            // copy that arrived" to describe, so neither the banner nor the
            // cached-failure sentence is true for it. Stay silent; the page
            // itself already explains the state.
            if !RemoteMarkdownSnapshotFetcher.isFailureDocumentPath(tab.fileURL) {
                RemoteSnapshotStalePolicy.note(.remoteRefreshFailed, path: path)
                if ownsFailureAnnouncement,
                    announceOutcome || announceFailure,
                    !attempt.hasFailurePresenter
                {
                    onAnnounceFailure()
                }
            }
            return nil
        }
        // A closed tab must not be resurrected by a late fetch — same contract
        // as branch-changes Refresh carrying its originating document id.
        guard let liveSession = sessionStore.session(id: sessionID) else {
            return nil
        }
        guard liveSession.layout.firstDocumentGroup?.tab(id: documentID) != nil else {
            if announceOutcome,
                ownsAnnouncements,
                attempt.hasCoalescedInteractiveConsumer
            {
                onAnnounceOutcome(outcome)
            }
            return nil
        }
        let openedID = apply(
            outcome,
            in: sessionID,
            associatedWith: paneID,
            sessionStore: sessionStore,
            selectingTab: selectingTab,
            announceOutcome: false
        )
        if announceOutcome, ownsAnnouncements, openedID != nil {
            onAnnounceOutcome(outcome)
        }
        return outcome
    }

    /// Marks restored snapshots as saved copies unless launch fetching is enabled.
    /// Opted-in fetches update tabs in place without changing selection.
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
        automaticallyRefresh: Bool,
        coordinator: RemoteMarkdownRefreshCoordinator? = nil,
        fetch: (@MainActor (RemoteMarkdownReference) async -> RemoteMarkdownFetchOutcome?)? = nil
    ) {
        let targets = interleavedRestoreTargets(restoreTargets(in: store))
        guard !targets.isEmpty else { return }
        guard automaticallyRefresh else {
            for target in targets {
                guard let tab = store.session(id: target.sessionID)?.layout.firstDocumentGroup?.tab(id: target.documentID),
                    !RemoteMarkdownSnapshotFetcher.isFailureDocumentPath(tab.fileURL)
                else { continue }
                // The banner is rendered only after a successful document load.
                RemoteSnapshotStalePolicy.note(.remoteNotRefreshed, path: tab.fileURL.standardizedFileURL.path)
            }
            return
        }
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
                            // Speak a failure only for the tab the user is
                            // looking at; background tabs stay silent and a
                            // launch-time success is never narrated.
                            announceFailure: isSelectedRestoreTarget(target, in: store),
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

    /// Spread admission across SSH destinations, keeping first-seen host order
    /// and the original tab order within each host. Match the fetch coordinator's
    /// serialization key so one host's queued tabs do not occupy every slot.
    static func interleavedRestoreTargets(_ targets: [RestoreTarget]) -> [RestoreTarget] {
        var hostIndices: [String: Int] = [:]
        var buckets: [[RestoreTarget]] = []
        for target in targets {
            let host = target.identity.remoteTarget?.sshDestination ?? "local"
            if let index = hostIndices[host] {
                buckets[index].append(target)
            } else {
                hostIndices[host] = buckets.count
                buckets.append([target])
            }
        }
        var result: [RestoreTarget] = []
        result.reserveCapacity(targets.count)
        var active = Array(buckets.indices)
        var offset = 0
        while !active.isEmpty {
            for index in active {
                result.append(buckets[index][offset])
            }
            offset += 1
            active.removeAll { buckets[$0].count == offset }
        }
        return result
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

    /// Whether `target` is the document tab the user is currently looking at.
    /// Restore uses it to decide which failure may speak: narrating every tab at
    /// launch would be noise, but a failure over the visible document is a
    /// status change the reader must hear.
    @MainActor
    static func isSelectedRestoreTarget(
        _ target: RestoreTarget,
        in store: SessionStore
    ) -> Bool {
        store.selectedSessionID == target.sessionID
            && store.session(id: target.sessionID)?.layout.firstDocumentGroup?.selectedTabID
                == target.documentID
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
