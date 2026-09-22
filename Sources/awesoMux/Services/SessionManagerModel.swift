import AwesoMuxBridgeProtocol
import AwesoMuxConfig
import AwesoMuxCore
import Foundation
import Observation

/// Owns the panel-open daemon poll, snapshot diffing → a11y announcements, and
/// the action surface (pin/unpin, reap, jump). Mirrors `DaemonGarbageCollector`'s
/// role for the launch sweep; all derivation is delegated to the pure
/// `DaemonStateResolver` / `SessionManagerSnapshotDiffer`.
@MainActor
@Observable
final class SessionManagerModel {
    enum ActivationResult: Equatable {
        case opened(sessionID: TerminalSession.ID, paneID: TerminalPane.ID)
        case restored(sessionID: TerminalSession.ID, paneID: TerminalPane.ID)
        case recovered(sessionID: TerminalSession.ID, paneID: TerminalPane.ID)
        case unavailable
        case changed
        case inventoryUnavailable
    }
    private(set) var rows: [DaemonRow] = []
    private(set) var activatingID: TerminalSessionID?
    private(set) var activationStatus: String?

    @ObservationIgnored private let store: SessionStore
    @ObservationIgnored private let settings: AppSettingsStore
    @ObservationIgnored private let policy: DaemonPolicyStore
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private let pollIntervalNanos: UInt64
    /// Posts a spoken string to VoiceOver — injected so it's testable / panel-scoped.
    @ObservationIgnored var announce: (String) -> Void = { _ in }

    init(store: SessionStore, settings: AppSettingsStore,
         policy: DaemonPolicyStore = DaemonPolicyStore(),
         pollIntervalNanos: UInt64 = 4_000_000_000) {
        self.store = store
        self.settings = settings
        self.policy = policy
        self.pollIntervalNanos = pollIntervalNanos
    }

    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: self?.pollIntervalNanos ?? 4_000_000_000)
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refresh() async {
        // An unavailable inventory or process snapshot keeps the last good rows;
        // neither failure proves that every daemon vanished or became idle.
        guard let live = await AmxBackend.listSessionsResult() else { return }
        guard let snapshot = await AmxBackend.currentProcessSnapshot() else { return }
        let reach = DaemonGCPlan.reachability(
            groups: store.groups,
            recentlyClosed: store.recentlyClosed,
            lastClosedTransient: store.lastClosedTransient
        )
        var idleByID: [TerminalSessionID: Bool] = [:]
        for d in live { idleByID[d.id] = AmxBackend.isIdle(d, snapshot: snapshot) }

        // Prune stale pins each cycle so the file can't grow unbounded.
        policy.prunePins(keepingOnly: Set(live.map(\.id)))

        let terminalConfig = settings.terminal.value
        let cap: Int? = terminalConfig.daemonIdleCapEnabled
            ? terminalConfig.daemonIdleCapMinutes * 60
            : nil

        let resolved = DaemonStateResolver.resolve(.init(
            live: live,
            idleByID: idleByID,
            ownedByLivePane: reach.livePane,
            restorable: reach.restorable,
            owners: ownerLabels(),
            pinned: policy.pinnedIDs,
                livePresentation: livePresentations(),
                snapshotPresentation: snapshotPresentations(),
            capThresholdSeconds: cap,
            now: Int(Date().timeIntervalSince1970)
        ))

        let sorted = resolved.sorted { lhs, rhs in
            groupOrder(lhs.lifecycle) < groupOrder(rhs.lifecycle)
        }
        for change in SessionManagerSnapshotDiffer.changes(from: rows, to: sorted) {
            announce(change.spoken)
        }
        rows = sorted
    }

    /// The real auto-cleanup cap state for the footer + its a11y label. Defaults
    /// to disabled (`daemonIdleCapEnabled == false`), so the footer must say "off"
    /// rather than advertising a 7-day reap that never fires. `days` is only
    /// meaningful when `enabled`.
    var capSummary: (enabled: Bool, days: Int) {
        let config = settings.terminal.value
        return (config.daemonIdleCapEnabled, max(1, config.daemonIdleCapMinutes / 1440))
    }

    func setPinned(_ pinned: Bool, for id: TerminalSessionID) {
        policy.setPinned(pinned, for: id)
        Task { await refresh() }
    }

    func setActivationState(id: TerminalSessionID?, status: String?) {
        activatingID = id
        activationStatus = status
    }

    /// Reaps a daemon after a fresh pre-kill revalidation. The panel poll is up to
    /// one interval stale and the confirm dialog adds more delay, so an orphan the
    /// user confirmed against may have been reattached (e.g. a restore-attach or a
    /// reopened workspace) and is now live. Mirror the launch sweep: re-list, run
    /// `DaemonReapGuard`, and abort+refresh rather than `--force`-kill a daemon the
    /// dialog promised was safe. Returns whether `amx kill` exited 0 (not a confirmed
    /// reap — see `AmxBackend.killSession` docs); a guard-aborted reap returns false.
    func reap(_ row: DaemonRow) async -> Bool {
        let current = await AmxBackend.listSessions().first { $0.id == row.id }
        let target = DaemonReapGuard.Target(
            id: row.id, pid: row.pid, createdEpoch: row.createdEpoch, lifecycle: row.lifecycle
        )
        guard DaemonReapGuard.mayReap(target: target, current: current) else {
            // The daemon is gone, recycled, or got reattached since the user saw the
            // row — re-render its true current state instead of killing it.
            await refresh()
            return false
        }
        let ok = await AmxBackend.killSession(row.id)
        await refresh()
        return ok
    }

    func activate(_ row: DaemonRow) async -> ActivationResult {
        guard let live = await AmxBackend.listSessionsResult() else {
            return .inventoryUnavailable
        }
        guard let daemon = live.first(where: { $0.id == row.id }) else {
            await refresh()
            return .unavailable
        }
        guard daemon.pid == row.pid, daemon.createdEpoch == row.createdEpoch else {
            await refresh()
            return .changed
        }
        if row.daemonPID != daemon.daemonPID {
            await refresh()
            return .changed
        }
        if let target = jumpTarget(for: row.id) {
            return .opened(sessionID: target.sessionID, paneID: target.paneID)
        }
        guard daemon.clients == 0 else {
            await refresh()
            return .changed
        }

        SessionRecoveryConfirmationCenter.shared.begin(
            row.id, daemonPID: daemon.daemonPID, createdEpoch: daemon.createdEpoch
        )
        let provisional: DaemonRecoveryHandle
        let kind: ActivationResultKind
        if let entry = store.recentlyClosedWorkspace(containing: row.id),
            let restored = store.provisionallyRestore(entry, daemonID: row.id)
        {
            provisional = restored
            kind = .restored
        } else if let recovered = store.recoverDaemon(
            id: row.id,
            metadata: daemon.recoveryMetadata
                ?? DaemonRecoveryMetadata(
                    workspaceTitle: nil, paneTitle: nil, groupID: nil, groupName: nil,
                    groupRemote: nil, agentKind: nil),
            cwd: daemon.cwd
        ) {
            provisional = recovered
            kind = .recovered
        } else {
            SessionRecoveryConfirmationCenter.shared.cancel(row.id)
            return .unavailable
        }

        guard await SessionRecoveryConfirmationCenter.shared.wait(for: row.id) else {
            store.rollbackDaemonRecovery(provisional)
            await refresh()
            return .unavailable
        }
        store.completeDaemonRecovery(provisional)
        store.drainRecentlyClosed(containing: row.id)
        await refresh()
        switch kind {
        case .restored:
            return .restored(sessionID: provisional.sessionID, paneID: provisional.paneID)
        case .recovered:
            return .recovered(sessionID: provisional.sessionID, paneID: provisional.paneID)
        }
    }

    private enum ActivationResultKind { case restored, recovered }

    // MARK: - Jump target

    /// Returns the (groupID, sessionID) needed to select a live workspace pane that
    /// owns this daemon. Returns nil when the daemon has no live pane owner.
    func jumpTarget(for id: TerminalSessionID) -> (
        groupID: UUID, sessionID: TerminalSession.ID, paneID: TerminalPane.ID
    )? {
        for group in store.groups {
            for session in group.sessions {
                if let pane = session.panes.first(where: { $0.terminalSessionID == id }) {
                    return (group.id, session.id, pane.id)
                }
            }
        }
        return nil
    }

    // MARK: - Owner labels

    // Walks the live workspace tree to build "workspace · pane" labels keyed by
    // TerminalSessionID. Kept here because it reads @MainActor store state; if
    // the formatting logic grows, extract a pure Core helper and add a unit test.
    private func ownerLabels() -> [TerminalSessionID: String] {
        var labels: [TerminalSessionID: String] = [:]
        for group in store.groups {
            for session in group.sessions {
                session.layout.forEachPane { pane in
                    labels[pane.terminalSessionID] = "\(session.title) · \(pane.title)"
                }
            }
        }
        return labels
    }

    private func livePresentations() -> [TerminalSessionID: DaemonPresentation] {
        DaemonPresentationProjector.live(groups: store.groups)
    }

    private func snapshotPresentations() -> [TerminalSessionID: DaemonPresentation] {
        DaemonPresentationProjector.snapshots(
            recentlyClosed: store.recentlyClosed,
            lastClosedTransient: store.lastClosedTransient
        )
    }

    // MARK: - Ordering

    private func groupOrder(_ life: DaemonLifecycle) -> Int {
        switch life {
        case .owned:               return 0
        case .detachedRestorable:  return 1
        case .abandoned:           return 2
        case .expired:             return 3
        case .inUseElsewhere:      return 4
        }
    }
}
