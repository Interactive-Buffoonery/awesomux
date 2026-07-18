import Foundation
import Observation

@MainActor
@Observable
public final class SessionStore {
    // Mutation post-condition matrix (F30 — commit(_:now:) is sole derived-state writer):
    //   1. Structural: commit(needsFullRebuild: true) [+ selection: .set when needed].
    //   2. Bulk restore (replaceState): isReplacingState + reset reducers inline,
    //      then commit(needsFullRebuild: true).
    //   3. Attention / risk / remote membership: commit(unreadChange / riskSessionIDs /
    //      remotePaneMembership). Multiple commits per public entry are allowed.
    //   4. No-commit family: rename group, set color, set active pane, pin reorder,
    //      markAgentActivityObserved (INT-420/523), updateShellActivity (INT-523).
    nonisolated public static let defaultAcknowledgementDwellNanoseconds: UInt64 = 500_000_000
    nonisolated public static let maxRecentlyClosed: Int = RecentlyClosedWorkspaceReducer.maxRecentlyClosed
    nonisolated public static let recentlyClosedTTL: TimeInterval = RecentlyClosedWorkspaceReducer.recentlyClosedTTL
    nonisolated public static let appendIndex: Int = .max
    nonisolated public static let shellActivityBusyDebounceInterval: TimeInterval = 0.25
    nonisolated public static let shellActivityIdleDebounceInterval: TimeInterval = 0.10

    var _groups: [SessionGroup]

    /// Ordered pin list for the sidebar's synthetic Pinned section. Membership
    /// = pinned, array order = display order. Sessions stay inside their
    /// origin group; this is a render-time projection input, never a move
    /// (INT-737).
    public internal(set) var pinnedSessionIDs: [TerminalSession.ID] = []

    @ObservationIgnored lazy var localHostnames: Set<String> = LocalHostnames.resolve()
    @ObservationIgnored var index: SessionStoreIndex = .empty
    @ObservationIgnored var shellActivityReducer = ShellActivityReducer()
    @ObservationIgnored var runtimeEventReducer = AgentRuntimeEventReducer()
    @ObservationIgnored let acknowledgementCoordinator: SelectionAcknowledgementCoordinator
    @ObservationIgnored private var isReplacingState = false
    @ObservationIgnored private var storedSelectedSessionID: TerminalSession.ID?
    @ObservationIgnored private weak var storedUndoManager: UndoManager?

    @ObservationIgnored public var undoManager: UndoManager? {
        get { storedUndoManager }
        set {
            guard storedUndoManager !== newValue else { return }
            storedUndoManager?.removeAllActions(withTarget: self)
            storedUndoManager = newValue
        }
    }

    /// Identifies an app-owned compact terminal store. Its surfaces receive a
    /// shared shell marker, while each compact surface may add a more specific
    /// marker of its own. The app itself does not filter shell startup output.
    /// This is runtime-only because compact terminal sessions do not survive
    /// relaunch in v1.
    @ObservationIgnored public internal(set) var compactTerminalKind: CompactTerminalKind?

    public var groups: [SessionGroup] {
        _groups
    }

    // Same-value writes must keep notifying observers: clicking the already-
    // selected sidebar tile re-assigns the same ID, and that publication re-runs
    // the surface mount whose focus reclaim hands the terminal first responder
    // (INT-652). The synthesized @Observable setter suppresses equal writes, so
    // this property uses explicit tracking around an ignored backing value.
    public var selectedSessionID: TerminalSession.ID? {
        get {
            access(keyPath: \.selectedSessionID)
            return storedSelectedSessionID
        }
        set {
            let changed = storedSelectedSessionID != newValue
            withMutation(keyPath: \.selectedSessionID) {
                storedSelectedSessionID = newValue
            }
            guard changed, !isReplacingState else { return }
            scheduleAcknowledgementForSelectedSession()
        }
    }

    public internal(set) var unreadNotificationTotal: Int = 0
    public internal(set) var recentlyClosed: [RecentlyClosedWorkspace] = []
    public internal(set) var lastClosedTransient: RecentlyClosedWorkspace?

    public init(
        groups: [SessionGroup] = [],
        selectedSessionID: TerminalSession.ID? = nil,
        recentlyClosed: [RecentlyClosedWorkspace] = [],
        pinnedSessionIDs: [TerminalSession.ID] = [],
        acknowledgementDwellNanoseconds: UInt64 = SessionStore.defaultAcknowledgementDwellNanoseconds
    ) {
        self._groups = groups
        self.storedSelectedSessionID = selectedSessionID ?? groups.first?.sessions.first?.id
        self.recentlyClosed = recentlyClosed
        self.acknowledgementCoordinator = SelectionAcknowledgementCoordinator(
            dwellNanoseconds: acknowledgementDwellNanoseconds
        )
        // Assign before commit(needsFullRebuild) so pin prune validates restored
        // pins against the freshly built index rather than an empty one (INT-737).
        self.pinnedSessionIDs = pinnedSessionIDs
        commit(WorkspaceMutationEffect(needsFullRebuild: true))
    }

    public convenience init(restoring snapshot: SessionSnapshot) {
        let components = SessionRestoreReducer.restoredComponents(from: snapshot)
        self.init(
            groups: components.groups,
            selectedSessionID: components.selectedSessionID,
            recentlyClosed: components.recentlyClosed,
            pinnedSessionIDs: components.pinnedSessionIDs
        )
    }

    private func registerUndo(
        actionName: String,
        handler: @escaping (SessionStore) -> Void
    ) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { target in
            handler(target)
        }
        undoManager.setActionName(actionName)
    }

    /// Atomically replaces store state with components restored from a sanitized `SessionSnapshot`.
    ///
    /// Pending selection acknowledgements are cancelled before replacement. The replacement swaps in
    /// the restored workspace groups, selected session, and recently closed workspaces; clears
    /// runtime-only state including `lastClosedTransient`, the shell activity reducer, and the
    /// runtime event reducer; then rebuilds derived state. Persisted badge counts are not restored:
    /// the restore reducer reconstructs each session without its `unreadNotificationCount`, so unread
    /// notification totals are reset to zero as part of the rebuild.
    @discardableResult
    public func replaceState(
        restoring snapshot: SessionSnapshot
    ) -> SessionRestoreSanitizationSummary {
        let components = SessionRestoreReducer.restoredComponents(from: snapshot)

        // A bulk restore can reuse group/session IDs with different values, so
        // surviving undo registrations would "revert" the restored state to
        // pre-restore values. Registered history is only valid for the state
        // identity it was recorded against — drop it at this boundary.
        storedUndoManager?.removeAllActions(withTarget: self)
        acknowledgementCoordinator.cancel()
        isReplacingState = true
        defer { isReplacingState = false }
        _groups = components.groups
        recentlyClosed = components.recentlyClosed
        pinnedSessionIDs = components.pinnedSessionIDs
        lastClosedTransient = nil
        shellActivityReducer = ShellActivityReducer()
        runtimeEventReducer = AgentRuntimeEventReducer()
        commit(
            WorkspaceMutationEffect(
                needsFullRebuild: true,
                selection: .set(components.selectedSessionID)
            )
        )
        return components.sanitizationSummary
    }

    public static func restore(
        from snapshot: SessionSnapshot
    ) -> (store: SessionStore, sanitizationSummary: SessionRestoreSanitizationSummary) {
        let components = SessionRestoreReducer.restoredComponents(from: snapshot)
        let store = SessionStore(
            groups: components.groups,
            selectedSessionID: components.selectedSessionID,
            recentlyClosed: components.recentlyClosed,
            pinnedSessionIDs: components.pinnedSessionIDs
        )
        return (store, components.sanitizationSummary)
    }

    public var selectedSession: TerminalSession? {
        guard let selectedSessionID else { return nil }
        return session(id: selectedSessionID)
    }

    public func session(id: TerminalSession.ID) -> TerminalSession? {
        guard let position = index.positionsBySessionID[id] else {
            return nil
        }
        return _groups[position.groupIndex].sessions[position.sessionIndex]
    }

    /// Sessions currently at risk of losing work on quit. Durable-risk sessions
    /// are cached; freshness-candidate sessions are time-filtered live against
    /// `now` since their risk can lapse purely from elapsed time (INT-420).
    ///
    /// NOT safe to read reactively from a SwiftUI `body`: this mostly reads
    /// `@ObservationIgnored index`, so a safe->risk transition where the
    /// freshness-candidate set stays empty touches no `@Observable`-tracked
    /// property. Current callers are imperative AppKit quit-lifecycle reads
    /// (`applicationShouldTerminate`); if a reactive SwiftUI consumer is ever
    /// added, mirror the count into an observed stored property first, the way
    /// `unreadNotificationTotal` already is.
    public var sessionsAtRiskOnQuit: [TerminalSession] {
        sessionsAtRiskOnQuit(at: Date())
    }

    /// Sessions that would lose work if CLOSED (destroyed) right now. Unlike
    /// `sessionsAtRiskOnQuit`, bridged panes are NOT authoritatively safe —
    /// a close kills their daemon session too. Uncached direct evaluation:
    /// callers are small single-session stores (the compact terminals), not
    /// the per-keystroke quit-gate path the quit cache exists for.
    public func sessionsAtRiskOnClose(at now: Date = Date()) -> [TerminalSession] {
        _groups.lazy.flatMap(\.sessions).filter { $0.isCloseRisk(at: now) }
    }

    func sessionsAtRiskOnQuit(at now: Date) -> [TerminalSession] {
        guard hasUniqueSessionIDs else {
            // The ID-keyed cache can't distinguish WHICH duplicate-ID occurrence
            // is actually at risk (`position(for:)` always resolves to the first
            // one) — fall back to evaluating every session value directly, same
            // as before this cache existed, rather than risk under-reporting
            // quit risk for a session that's merely a duplicate (INT-420).
            return _groups.lazy.flatMap(\.sessions).filter { $0.isQuitRisk(at: now) }
        }
        let freshRiskIDs = freshnessCandidateSessionIDsCurrentlyAtRisk(at: now)
        // Walk `_groups` in order (not the sets) to preserve existing workspace-order determinism.
        return _groups.lazy.flatMap(\.sessions).filter {
            index.durableAtRiskSessionIDs.contains($0.id) || freshRiskIDs.contains($0.id)
        }
    }

    public var sessionsAtRiskOnQuitCount: Int {
        sessionsAtRiskOnQuitCount(at: Date())
    }

    func sessionsAtRiskOnQuitCount(at now: Date) -> Int {
        guard hasUniqueSessionIDs else {
            return _groups.lazy.flatMap(\.sessions).reduce(0) { $0 + ($1.isQuitRisk(at: now) ? 1 : 0) }
        }
        return index.durableAtRiskSessionIDs.count + freshnessCandidateSessionIDsCurrentlyAtRisk(at: now).count
    }

    /// Cheap O(session count) uniqueness check, NOT gated behind DEBUG — unlike
    /// the assertion below, this gates real RELEASE-mode behavior. Duplicate
    /// session IDs are a tolerated anomaly elsewhere in this store (see
    /// `unreadNotificationTotal`'s first-occurrence-wins handling), but for a
    /// value whose entire purpose is warning before data loss, "possibly wrong"
    /// isn't an acceptable degradation — only the brute-force fallback is (INT-420).
    private var hasUniqueSessionIDs: Bool {
        let allIDs = _groups.flatMap { $0.sessions.map(\.id) }
        return Set(allIDs).count == allIDs.count
    }

    /// Filters `freshnessCandidateSessionIDs` down to sessions still within the
    /// staleness window at `now`. Reuses `TerminalPane.isQuitRisk` directly rather
    /// than re-deriving the freshness condition, so this can never drift from
    /// `QuitRiskPolicy`.
    ///
    /// Ceiling: this is the one part of the read path that isn't O(1) — it's
    /// O(candidate sessions), bounded by concurrent in-flight non-shell agent
    /// executions rather than total session count. Revisit if agent fleets grow
    /// to thousands of concurrently-executing sessions.
    private func freshnessCandidateSessionIDsCurrentlyAtRisk(at now: Date) -> Set<TerminalSession.ID> {
        index.freshnessCandidateSessionIDs.filter { sessionID in
            guard let position = position(for: sessionID) else { return false }
            return _groups[position.groupIndex].sessions[position.sessionIndex]
                .panes.contains { $0.isQuitRisk(at: now) }
        }
    }

    #if DEBUG
        /// Verifies the cached quit-risk sets agree with a brute-force recompute
        /// using the SAME `now` on both sides, so this can't spuriously fail near
        /// the 60s staleness boundary (INT-420). Skipped under duplicate session IDs
        /// for the same reason the sibling `unreadNotificationTotal` assert above
        /// skips itself: the cache sets dedupe by ID while the brute-force sum does
        /// not, so the two are not comparable when IDs collide (a tolerated existing
        /// anomaly, not something this cache needs to define new semantics for).
        func assertQuitRiskCacheMatches(now: Date) {
            guard hasUniqueSessionIDs else { return }
            // Compare full ID sets, not just counts: a count-only comparison can
            // mask one stale false positive canceling out one stale false negative.
            let cachedIDs = Set(sessionsAtRiskOnQuit(at: now).map(\.id))
            let bruteForceIDs = Set(
                _groups.lazy.flatMap(\.sessions).filter { $0.isQuitRisk(at: now) }.map(\.id)
            )
            assert(cachedIDs == bruteForceIDs, "sessionsAtRiskOnQuitCount cache drift detected")
        }
    #endif

    /// How long the freshness stamp is allowed to coast before a new activity
    /// observation rewrites it. This bump exists ONLY to keep a long-running,
    /// same-state agent from aging into quit-risk staleness
    /// (`TerminalPane.staleAgentActivityThreshold` = 60s). It is never displayed,
    /// yet it lives in the `@Observable` model, so writing a fresh `Date` on every
    /// ~0.5s activity sample re-rendered the entire sidebar for nothing — the
    /// dominant INT-523 scroll-stutter trigger. Coarsening to a fraction of the
    /// staleness window keeps freshness with comfortable margin while collapsing a
    /// stream of activity into at most one store mutation per interval.
    ///
    /// Ceiling: freshness genuinely belongs outside the observed display model
    /// (a runtime-only side table keyed by paneID). Until that refactor, this
    /// coarsening is the cheap fix; it can make quit-risk staleness fire up to
    /// this interval early, which is immaterial against a 60s heuristic.
    ///
    /// `nonisolated`: a plain compile-time constant with no actor-isolated
    /// state — `WorkspaceAttentionReducer` (deliberately nonisolated/`Sendable`
    /// so it stays testable without SwiftUI) reads it directly from
    /// `updatePane` to coarsen the same heartbeat this doc comment describes.
    nonisolated static let agentActivityFreshnessCoarsening: TimeInterval = 10

    /// Deliberately does NOT call `reclassifyRiskMembership` — only bumps
    /// `lastAgentStateChangeAt`, which quit-risk classification doesn't read
    /// (see the doc comment on `reclassifyRiskMembership`, INT-420).
    ///
    /// Also deliberately state-agnostic: this bumps the freshness stamp for
    /// ANY `agentExecutionState`, including `.idle`/`.done`/`.error`, with no
    /// gate on which states count as "worth refreshing". Gating here would
    /// duplicate a policy decision that already lives on the read side —
    /// `isQuitRisk`/`classifySessionRisk` are what decide whether a pane's
    /// state makes it quit-risk-eligible in the first place; this call only
    /// answers "is the observed activity still fresh," which is meaningless
    /// to filter by state a second time.
    public func markAgentActivityObserved(
        id: TerminalSession.ID,
        paneID: TerminalPane.ID? = nil
    ) {
        guard let position = position(for: id),
            let targetPaneID = resolvedPaneID(sessionID: id, paneID: paneID)
        else {
            return
        }
        let now = Date()
        // Resolve the pane up front and bail if it's gone (a close-vs-sample
        // race): otherwise the `mappingPanes` reassignment below fires
        // @Observable for a pane that no longer exists — a phantom no-op publish,
        // the exact thing this coarsening exists to avoid. Skip the mutation
        // entirely when the existing stamp is still fresh enough.
        guard
            let currentPane = _groups[position.groupIndex]
                .sessions[position.sessionIndex]
                .layout.pane(id: targetPaneID)
        else {
            return
        }
        if now.timeIntervalSince(currentPane.lastAgentStateChangeAt)
            < Self.agentActivityFreshnessCoarsening
        {
            return
        }
        _groups[position.groupIndex].sessions[position.sessionIndex].layout =
            _groups[position.groupIndex].sessions[position.sessionIndex].layout.mappingPanes { pane in
                guard pane.id == targetPaneID else { return pane }
                var pane = pane
                pane.lastAgentStateChangeAt = now
                return pane
            }
    }

    /// Pane-keyed snapshots are the only quit-confirm sync entry point: tests
    /// drive the same interface production does. Single-pane construction
    /// convenience lives in test support (`TerminalQuitConfirmationSnapshot.active`),
    /// deliberately kept out of this module so no session-keyed seam can silently
    /// clear a sibling pane's flag (C3 / INT-504 R4).
    public func updateTerminalQuitConfirmationRisks(
        _ snapshots: [TerminalQuitConfirmationSnapshot]
    ) {
        // `apply` walks every session (including ones absent from `snapshots`,
        // which it resets to safe), so the changed-session set it returns is the
        // only reliable way to know which sessions to reclassify (INT-420).
        let changedSessionIDs = TerminalQuitConfirmationReducer.apply(
            risksByPaneID: TerminalQuitConfirmationReducer.risks(from: snapshots),
            promptObservedByPaneID: TerminalQuitConfirmationReducer.promptObserved(from: snapshots),
            livenessByPaneID: TerminalQuitConfirmationReducer.liveness(from: snapshots),
            to: &_groups
        )
        guard !changedSessionIDs.isEmpty else { return }
        commit(
            WorkspaceMutationEffect(riskSessionIDs: Set(changedSessionIDs)),
            now: Date()
        )
    }

    /// Pane-keyed snapshots are the only shell-activity sync entry point; see the
    /// note on `updateTerminalQuitConfirmationRisks`. Single-pane construction
    /// convenience lives in test support, so tests pass through the same per-pane
    /// prompt-seen trust gate (`ShellActivityReducer`) production does (C3).
    @discardableResult
    public func updateShellActivity(
        _ snapshots: [ShellActivitySnapshot],
        now: Date = Date()
    ) -> Bool {
        // Run on a LOCAL copy so the reducer's `inout` doesn't fire @Observable:
        // passing `&_groups` directly copies back on return every call (even with
        // no change), re-rendering the whole sidebar on every idle shell sample
        // (INT-523 scroll stutter). Publish only when a pane's activity changed.
        var copy = _groups
        let result = shellActivityReducer.update(snapshots: snapshots, groups: &copy, now: now)
        if result.didChange {
            _groups = copy
        }
        return result.hasPendingDebounce
    }

    public func selectFirstSessionIfNeeded() {
        guard selectedSessionID == nil else { return }
        selectedSessionID = WorkspaceTreeReducer.firstSessionID(in: _groups)
    }

    public func snapshot() -> SessionSnapshot {
        // Filter at serialization time, not just at close/reopen/launch:
        // prune is otherwise lazy, and every debounced save would re-stamp
        // expired paths into backup history (ADR 0015).
        let cutoff = Date().addingTimeInterval(-Self.recentlyClosedTTL)
        return SessionSnapshot(
            groups: _groups,
            selectedSessionID: selectedSessionID,
            recentlyClosed: recentlyClosed.filter { $0.closedAt >= cutoff },
            pinnedSessionIDs: pinnedSessionIDs
        )
    }

    @discardableResult
    public func addSession(
        title: String? = nil,
        workingDirectory: String? = nil,
        agentKind: AgentKind = .shell,
        groupName: String = "awesoMux"
    ) -> TerminalSession.ID {
        let sessionID = WorkspaceTreeReducer.addSession(
            to: &_groups,
            selectedSession: selectedSession,
            title: title,
            workingDirectory: workingDirectory,
            agentKind: agentKind,
            groupName: groupName
        )
        commit(
            WorkspaceMutationEffect(
                needsFullRebuild: true,
                selection: .set(sessionID)
            )
        )
        return sessionID
    }

    public func insertSession(
        _ session: TerminalSession,
        groupName: String,
        select: Bool = true
    ) {
        WorkspaceTreeReducer.insertSession(
            session,
            into: &_groups,
            groupName: groupName
        )
        if select {
            commit(
                WorkspaceMutationEffect(
                    needsFullRebuild: true,
                    selection: .set(session.id)
                )
            )
        } else {
            commit(WorkspaceMutationEffect(needsFullRebuild: true))
        }
    }

    @discardableResult
    public func addSSHSession(
        target: RemoteTarget,
        toGroupID groupID: SessionGroup.ID
    ) -> TerminalSession.ID? {
        guard target.isSafeSSHDestination else { return nil }
        guard
            let sessionID = WorkspaceTreeReducer.addSession(
                to: &_groups,
                selectedSession: selectedSession,
                groupID: groupID,
                executionPlan: .ssh(SSHExecution(target: target))
            )
        else { return nil }
        commit(WorkspaceMutationEffect(needsFullRebuild: true, selection: .set(sessionID)))
        return sessionID
    }

    @discardableResult
    public func addWorkspaceGroup(
        named rawGroupName: String,
        workingDirectory: String? = nil,
        agentKind: AgentKind = .shell
    ) -> TerminalSession.ID? {
        guard
            let sessionID = WorkspaceTreeReducer.addWorkspaceGroup(
                to: &_groups,
                selectedSession: selectedSession,
                named: rawGroupName,
                workingDirectory: workingDirectory,
                agentKind: agentKind
            )
        else {
            return nil
        }
        commit(
            WorkspaceMutationEffect(
                needsFullRebuild: true,
                selection: .set(sessionID)
            )
        )
        return sessionID
    }

    public func containsGroup(named rawGroupName: String) -> Bool {
        WorkspaceTreeReducer.containsGroup(in: _groups, named: rawGroupName)
    }

    @discardableResult
    public func renameGroup(id groupID: SessionGroup.ID, to rawGroupName: String) -> Bool {
        guard let previousName = _groups.first(where: { $0.id == groupID })?.name else {
            return false
        }
        // No-commit family (F30): name change doesn't affect positions, panes,
        // unread, risk, or pins — no derived-cache repair.
        guard WorkspaceTreeReducer.renameGroup(in: &_groups, id: groupID, to: rawGroupName) else {
            return false
        }
        guard _groups.first(where: { $0.id == groupID })?.name != previousName else {
            return true
        }
        registerUndo(
            actionName: String(
                localized: "Rename Group",
                comment: "Undo action for renaming a workspace group."
            )
        ) { target in
            target.renameGroup(id: groupID, to: previousName)
        }
        return true
    }

    @discardableResult
    public func setGroupColor(
        id groupID: SessionGroup.ID,
        color: WorkspaceGroupColor?
    ) -> Bool {
        guard let group = _groups.first(where: { $0.id == groupID }) else {
            return false
        }
        let previousColor = group.color
        // Non-structural: color change doesn't affect positions, panes, or unread.
        guard WorkspaceTreeReducer.setGroupColor(in: &_groups, id: groupID, color: color) else {
            return false
        }
        guard _groups.first(where: { $0.id == groupID })?.color != previousColor else {
            return true
        }
        registerUndo(
            actionName: String(
                localized: "Set Group Color",
                comment: "Undo action for changing a workspace group color."
            )
        ) { target in
            target.setGroupColor(id: groupID, color: previousColor)
        }
        return true
    }

    /// Create a group whose default and seed pane use `target`.
    /// Mirrors `addWorkspaceGroup`.
    @discardableResult
    public func createRemoteWorkspaceGroup(
        named rawGroupName: String,
        target: RemoteTarget
    ) -> TerminalSession.ID? {
        guard target.isSafeSSHDestination else { return nil }
        let seeded = WorkspaceTreeReducer.addWorkspaceGroup(
            to: &_groups,
            selectedSession: selectedSession,
            named: rawGroupName,
            workingDirectory: nil,
            agentKind: .shell,
            remote: target
        )
        guard let seeded else { return nil }
        commit(
            WorkspaceMutationEffect(
                needsFullRebuild: true,
                selection: .set(seeded)
            )
        )
        return seeded
    }

    /// The active pane's declared SSH target, if any. Read-only — no publish.
    /// Used by the bridge spawn path to decide ssh-vs-local-shell.
    public func remoteTarget(forSessionID id: TerminalSession.ID) -> RemoteTarget? {
        guard let position = position(for: id) else { return nil }
        let session = _groups[position.groupIndex].sessions[position.sessionIndex]
        return session.activePane?.executionPlan.remoteTarget
    }

    /// Acknowledges the session's ACTIVE pane (selection dwell / per-row clear).
    /// A sibling pane still needing input keeps the workspace row loud — ⌘⇧K
    /// (`acknowledgeAllPanes(in:)`) clears the whole workspace, and "Clear All
    /// Notifications" (`acknowledgeAllSessions`) clears every workspace. ADR-0003
    /// amendment under INT-504.
    public func acknowledgeSession(id: TerminalSession.ID) {
        guard let position = position(for: id) else { return }
        if id == selectedSessionID {
            acknowledgementCoordinator.cancel()
        }
        let activePaneID = _groups[position.groupIndex]
            .sessions[position.sessionIndex].activePaneID
        let change = WorkspaceAttentionReducer.acknowledgePane(
            &_groups[position.groupIndex].sessions[position.sessionIndex],
            paneID: activePaneID
        )
        commit(WorkspaceMutationEffect(unreadChange: change))
    }

    /// Acknowledges every pane in ONE workspace — the ⌘⇧K "Acknowledge Workspace"
    /// escape hatch. Distinct from `acknowledgeSession` (active pane only) and
    /// `acknowledgeAllSessions` (every workspace). INT-504 R3.
    public func acknowledgeAllPanes(in id: TerminalSession.ID) {
        guard let position = position(for: id) else { return }
        if id == selectedSessionID {
            acknowledgementCoordinator.cancel()
        }
        let change = WorkspaceAttentionReducer.acknowledgeAllPanes(
            in: &_groups[position.groupIndex].sessions[position.sessionIndex]
        )
        commit(WorkspaceMutationEffect(unreadChange: change))
    }

    public func acknowledgeAllSessions() {
        acknowledgementCoordinator.cancel()
        WorkspaceAttentionReducer.acknowledgeAllSessions(in: &_groups)
        commit(WorkspaceMutationEffect(needsFullRebuild: true))
    }

    /// Who initiated a session/pane close — threaded through to the
    /// recently-closed persistence gate below. `.user` is the default so
    /// every existing explicit close path (⌘W, ⇧⌘W, palette, group close,
    /// sidebar) keeps persisting without having to name itself; only the
    /// shell-exit auto-close path passes `.processExit` explicitly.
    public enum CloseOrigin: Sendable {
        case user
        case processExit
    }

    /// Removes a workspace from `groups` and pushes a snapshot of it onto
    /// `recentlyClosed` so ⌘+⇧+T (Reopen Closed Workspace) can resurrect it.
    ///
    /// **Capture-on-close invariant (INT-415):** This is the single point
    /// at which a workspace is removed from `groups`. Explicit UI close
    /// gestures (⌘+⇧+W, sidebar context menu, sidebar close button, and
    /// single-pane ⌘W — `closeActivePane` routes that case through
    /// `closeWorkspace(_:)` too, see ADR-0002's amendment) funnel through
    /// `closeWorkspace(_:)` in `AwesoMuxApp`, which calls this method.
    /// Last-pane terminal process exit reaches this method via
    /// `closePane(id:in:)` so ⌘+⇧+T can resurrect that workspace too.
    ///
    /// Adjacent paths that do NOT reach here, by design:
    /// - **Explicit Restart Shell command** recycles the active pane's
    ///   shell in place via `recycleActivePane`. The workspace stays in
    ///   `groups` and is therefore NOT pushed to `recentlyClosed`.
    ///
    /// If a future refactor adds another removal path (e.g. group teardown
    /// with active sessions), it MUST push to `recentlyClosed` first or the
    /// reopen feature silently degrades. Capture is the default, not
    /// unconditional: see the permanent-clear exception below.
    ///
    /// Permanent clear (INT-282) passes `captureRecentlyClosed: false` — the
    /// same single removal point, deliberately without capture, so the
    /// workspace is unrecoverable by design. The caller owns daemon teardown;
    /// a live workspace never has a row in either reopen tier (reopen drains
    /// its entry and mints a fresh session id), so skipping capture is the
    /// whole "remove from the buffer" story.
    ///
    /// **Persistence-gate origin rule:** a deliberate user close always
    /// persists to the durable `recentlyClosed` list, even a "boring"
    /// plain-shell/~-cwd/untitled workspace — the quality gate
    /// (`isWorthRecording`) exists to keep noisy shell-exit AUTO-closes out
    /// of the list, not to filter closes the user asked for. `origin` is
    /// `.user` unless the caller is the process-exit auto-close path.
    public func closeSession(
        id: TerminalSession.ID,
        now: Date = Date(),
        captureRecentlyClosed: Bool = true,
        origin: CloseOrigin = .user
    ) {
        guard let position = position(for: id) else { return }

        let session = _groups[position.groupIndex].sessions[position.sessionIndex]
        let group = _groups[position.groupIndex]
        if captureRecentlyClosed {
            let capture = RecentlyClosedWorkspaceReducer.captureDecision(
                session: session,
                group: group,
                indexInGroup: position.sessionIndex,
                now: now
            )
            lastClosedTransient = capture.entry
            if origin == .user || capture.shouldPersist {
                recordRecentlyClosed(capture.entry, now: now)
            }
        }

        let selectedReplacementID =
            selectedSessionID == id
            ? WorkspaceTreeReducer.replacementSelectionAfterClosingSession(
                in: _groups,
                at: position
            )
            : selectedSessionID

        for paneID in session.layout.paneIDs {
            runtimeEventReducer.remove(paneID: paneID)
            shellActivityReducer.removePromptSeen(paneID: paneID)
            shellActivityReducer.removeDebounce(paneID: paneID)
        }
        _groups[position.groupIndex].sessions.remove(at: position.sessionIndex)
        commit(
            WorkspaceMutationEffect(
                needsFullRebuild: true,
                selection: .set(selectedReplacementID)
            ),
            now: now
        )
    }

    /// Retract any reopen entry captured for `sessionID` from both tiers.
    ///
    /// Backs permanent clear's race with a self-closing workspace (INT-282):
    /// if the last pane's process exits while the clear-confirm dialog is up,
    /// the exit path soft-closes the session through `closeSession` and
    /// captures a reopen entry — coexisting with a confirmed "can't be
    /// reopened" promise. `sessionID` is unique per close (reopen mints fresh
    /// ids), so at most one entry per tier can match.
    public func forgetRecentlyClosed(sessionID: TerminalSession.ID) {
        if lastClosedTransient?.sessionID == sessionID {
            lastClosedTransient = nil
        }
        recentlyClosed.removeAll { $0.sessionID == sessionID }
    }

    public var canReopenClosedWorkspace: Bool {
        canReopenClosedWorkspace(now: Date())
    }

    public func canReopenClosedWorkspace(now: Date) -> Bool {
        let cutoff = now.addingTimeInterval(-Self.recentlyClosedTTL)
        return (lastClosedTransient?.closedAt ?? .distantPast) >= cutoff
            || recentlyClosed.contains { $0.closedAt >= cutoff }
    }

    @discardableResult
    public func reopenMostRecentlyClosed(now: Date = Date()) -> TerminalSession.ID? {
        let reopenedID = RecentlyClosedWorkspaceReducer.reopenMostRecentlyClosed(
            in: &_groups,
            recentlyClosed: &recentlyClosed,
            lastClosedTransient: &lastClosedTransient,
            now: now
        )
        guard let reopenedID else {
            return nil
        }
        commit(
            WorkspaceMutationEffect(
                needsFullRebuild: true,
                selection: .set(reopenedID)
            ),
            now: now
        )
        return reopenedID
    }

    /// Reopen a specific recently-closed workspace (e.g. a Dock "Recent
    /// Workspaces" selection) rather than the most-recent one. The `entry`
    /// carries the snapshot to rebuild; the drained row is matched by identity
    /// fields `(sessionID, closedAt)`. Returns nil when the entry has already
    /// been reopened or aged out between the caller reading `recentWorkspaces`
    /// and this call.
    @discardableResult
    public func reopen(_ entry: RecentlyClosedWorkspace, now: Date = Date()) -> TerminalSession.ID? {
        let reopenedID = RecentlyClosedWorkspaceReducer.reopen(
            entry: entry,
            in: &_groups,
            recentlyClosed: &recentlyClosed,
            lastClosedTransient: &lastClosedTransient,
            now: now
        )
        guard let reopenedID else {
            return nil
        }
        commit(
            WorkspaceMutationEffect(
                needsFullRebuild: true,
                selection: .set(reopenedID)
            ),
            now: now
        )
        return reopenedID
    }

    /// The most recently closed workspaces for a chooser surface (the Dock
    /// "Recent Workspaces" submenu), newest first, TTL-pruned and capped. A
    /// read-only view: unlike `reopen`, it does not mutate the reopen tiers.
    /// Persisted tier only — the transient slot backs Cmd-Shift-T's immediate
    /// undo, not a durable recents list.
    public func recentWorkspaces(limit: Int = 5, now: Date = Date()) -> [RecentlyClosedWorkspace] {
        let cutoff = now.addingTimeInterval(-Self.recentlyClosedTTL)
        return Array(
            recentlyClosed
                .lazy
                .filter { $0.closedAt >= cutoff }
                .prefix(max(0, limit))
        )
    }

    /// Closes the group's workspaces through `closeSession` — keeping the
    /// capture-on-close invariant (INT-415), selection fixup, and per-pane
    /// reducer cleanup in the single existing path — then attempts to
    /// remove the group. Returns whether the group was removed:
    /// `removeGroup` refuses the last group (closing the sole group leaves
    /// the empty shell behind) and refuses a still-populated group.
    ///
    /// `limitedTo` restricts the close to sessions the caller already
    /// confirmed with the user — a session that joined the group after
    /// confirmation survives, and its presence keeps the group alive via
    /// `removeGroup`'s emptiness guard. `nil` closes all current members.
    ///
    /// `closeSession` rebuilds derived state once per iteration; group
    /// sizes are small and reusing the single close path is worth it over
    /// a batched removal that would have to re-implement its invariants.
    @discardableResult
    public func closeGroup(
        id: SessionGroup.ID,
        limitedTo confirmedSessionIDs: [TerminalSession.ID]? = nil,
        now: Date = Date()
    ) -> Bool {
        guard let group = _groups.first(where: { $0.id == id }) else { return false }
        for sessionID in group.sessions.map(\.id)
        where confirmedSessionIDs?.contains(sessionID) ?? true {
            closeSession(id: sessionID, now: now)
        }
        return removeGroup(id: id)
    }

    /// Returns whether the group was actually removed — the reducer refuses
    /// non-empty groups and the last group, and callers announcing the
    /// outcome must not claim a removal that was silently refused.
    @discardableResult
    public func removeGroup(id: SessionGroup.ID) -> Bool {
        guard WorkspaceTreeReducer.removeGroup(in: &_groups, id: id) else { return false }
        commit(WorkspaceMutationEffect(needsFullRebuild: true))
        return true
    }

    public func moveSession(
        id sessionID: TerminalSession.ID,
        toGroupID destinationGroupID: SessionGroup.ID,
        atIndex targetIndex: Int
    ) {
        guard let source = index.positionsBySessionID[sessionID] else { return }
        let sourceGroupID = _groups[source.groupIndex].id
        let sourceSessionIndex = source.sessionIndex
        guard
            WorkspaceTreeReducer.moveSession(
                in: &_groups,
                index: index,
                id: sessionID,
                toGroupID: destinationGroupID,
                atIndex: targetIndex
            )
        else {
            return
        }
        commit(WorkspaceMutationEffect(needsFullRebuild: true))
        registerUndo(
            actionName: String(
                localized: "Move Workspace",
                comment: "Undo action for moving a workspace within or between groups."
            )
        ) { target in
            target.moveSession(
                id: sessionID,
                toGroupID: sourceGroupID,
                atIndex: sourceSessionIndex
            )
        }
    }

    public func moveGroup(from sourceIndex: Int, to targetIndex: Int) {
        guard _groups.indices.contains(sourceIndex) else { return }
        let groupID = _groups[sourceIndex].id
        guard
            WorkspaceTreeReducer.moveGroup(
                in: &_groups,
                from: sourceIndex,
                to: targetIndex
            )
        else {
            return
        }
        commit(WorkspaceMutationEffect(needsFullRebuild: true))
        registerUndo(
            actionName: String(
                localized: "Move Group",
                comment: "Undo action for reordering a workspace group."
            )
        ) { target in
            // Resolve the moved group's index by ID at undo time: groups can be
            // added/removed between registration and undo, so a captured index
            // could reorder an unrelated group.
            guard let currentIndex = target._groups.firstIndex(where: { $0.id == groupID })
            else { return }
            target.moveGroup(from: currentIndex, to: sourceIndex)
        }
    }

    public func isPinned(_ id: TerminalSession.ID) -> Bool {
        pinnedSessionIDs.contains(id)
    }

    public func togglePin(sessionID: TerminalSession.ID) {
        if let pinnedIndex = pinnedSessionIDs.firstIndex(of: sessionID) {
            pinnedSessionIDs.remove(at: pinnedIndex)
            return
        }
        guard session(id: sessionID) != nil else { return }
        pinnedSessionIDs.append(sessionID)
    }

    /// Mirrors `WorkspaceTreeReducer.moveGroup`'s index convention exactly so
    /// Task 7's drag-reorder code can feed both call sites the same indices:
    /// `toIndex` is the desired FINAL index (not a pre-removal insertion
    /// point), clamped into the original array's bounds, with a no-op when
    /// that resolves to the source's own position.
    public func movePinnedSession(fromIndex: Int, toIndex: Int) {
        guard pinnedSessionIDs.indices.contains(fromIndex) else { return }
        let clampedTarget = max(0, min(toIndex, pinnedSessionIDs.count - 1))
        guard clampedTarget != fromIndex else { return }
        let id = pinnedSessionIDs.remove(at: fromIndex)
        pinnedSessionIDs.insert(id, at: min(clampedTarget, pinnedSessionIDs.count))
    }

    public func selectNextSession() {
        selectSession(offset: 1)
    }

    public func selectPreviousSession() {
        selectSession(offset: -1)
    }

    internal func selectSession(offset: Int) {
        selectedSessionID = WorkspaceTreeReducer.selectedSessionID(
            in: _groups,
            index: index,
            currentSelection: selectedSessionID,
            offset: offset
        )
    }

    @discardableResult
    public func splitActivePane(
        orientation: TerminalSplitOrientation,
        in sessionID: TerminalSession.ID? = nil
    ) -> TerminalPane.ID? {
        guard let sessionID = sessionID ?? selectedSessionID,
            let position = position(for: sessionID),
            let result = PaneLayoutReducer.splitActivePane(
                in: _groups[position.groupIndex].sessions[position.sessionIndex],
                orientation: orientation,
                now: Date()
            )
        else {
            return nil
        }
        _groups[position.groupIndex].sessions[position.sessionIndex] = result.session
        commit(WorkspaceMutationEffect(needsFullRebuild: true))
        return result.newPaneID
    }

    /// Opens a document as a tab in the given session's (or the selected
    /// session's) document viewer, creating the viewer split when none exists.
    /// Focus stays on the existing terminal. Returns the new or existing tab ID
    /// on success, or `nil` if the session cannot be found.
    ///
    /// `associatedWith` records which terminal pane the document's send/stage
    /// actions target. Pass the initiating pane when the open context knows it
    /// (terminal link click, agent hook). By default, when `nil`, the session's
    /// `activePaneID` is captured HERE, at open time — the tab stores a concrete
    /// pane id, never a floating "whatever is active later" fallback.
    /// Document-to-document opens use `.preserveNil` so stale source tabs cannot
    /// silently retarget to whichever terminal happens to be active.
    @discardableResult
    public func openDocumentPane(
        fileURL: URL,
        in sessionID: TerminalSession.ID? = nil,
        associatedWith associatedTerminalPaneID: TerminalPane.ID? = nil,
        remoteResourceIdentity: ResourceIdentity? = nil,
        associationPolicy: DocumentPaneAssociationPolicy = .captureActivePaneWhenNil
    ) -> DocumentPane.ID? {
        guard let sessionID = sessionID ?? selectedSessionID,
            let position = position(for: sessionID)
        else {
            return nil
        }
        let session = _groups[position.groupIndex].sessions[position.sessionIndex]
        let resolvedAssociation =
            associatedTerminalPaneID
            ?? (associationPolicy == .captureActivePaneWhenNil ? session.activePaneID : nil)
        guard
            let result = PaneLayoutReducer.openDocumentTab(
                fileURL: fileURL,
                associatedTerminalPaneID: resolvedAssociation,
                remoteResourceIdentity: remoteResourceIdentity,
                in: session,
                now: Date(),
                // A selection swap remounts the document view; while a comment
                // popover holds a typed draft over the current tab, append without
                // selecting instead of destroying it (INT-748). Only agent-driven
                // opens can observe true — any user-initiated open involved a
                // click that already dismissed the transient popover.
                selectingNewTab: !DocumentComposeGuard.isComposing()
            )
        else {
            return nil
        }
        // Dedup of an already-selected tab returns the session untouched — skip
        // the write and the full derived-state rebuild, matching how
        // selectDocumentTab treats a no-op. Agent hooks can re-emit the same
        // open repeatedly; each must not re-index the whole store.
        if result.session != session {
            _groups[position.groupIndex].sessions[position.sessionIndex] = result.session
            commit(WorkspaceMutationEffect(needsFullRebuild: true))
        }
        return result.newTabID
    }

    /// Selects a tab in the given session's (or the selected session's) document
    /// viewer. Never changes `activePaneID` — switching documents must not move
    /// terminal focus.
    public func selectDocumentTab(
        tabID: DocumentPane.ID,
        in sessionID: TerminalSession.ID? = nil
    ) {
        guard let sessionID = sessionID ?? selectedSessionID,
            let position = position(for: sessionID),
            let session = PaneLayoutReducer.selectDocumentTab(
                tabID: tabID,
                in: _groups[position.groupIndex].sessions[position.sessionIndex]
            )
        else {
            return
        }
        _groups[position.groupIndex].sessions[position.sessionIndex] = session
        commit(WorkspaceMutationEffect(needsFullRebuild: true))
    }

    /// Closes the document tab identified by `documentID` in the given session
    /// (or the selected session). Closing the last tab collapses the viewer's
    /// split back to the terminal layout. Focus stays on the existing terminal.
    public func closeDocumentPane(
        documentID: DocumentPane.ID,
        in sessionID: TerminalSession.ID? = nil
    ) {
        guard let sessionID = sessionID ?? selectedSessionID,
            let position = position(for: sessionID),
            let session = PaneLayoutReducer.closeDocumentTab(
                tabID: documentID,
                in: _groups[position.groupIndex].sessions[position.sessionIndex],
                now: Date()
            )
        else {
            return
        }
        _groups[position.groupIndex].sessions[position.sessionIndex] = session
        commit(WorkspaceMutationEffect(needsFullRebuild: true))
    }

    /// Replaces an existing document tab's file in-place (inline file-browser
    /// navigation), preserving the tab's terminal association; or, when the
    /// target file is already open in another tab, selects that tab and drops
    /// the navigating one. This is distinct from `openDocumentPane`, which adds
    /// a new tab for a different file.
    @discardableResult
    public func replaceDocumentPane(
        documentID: DocumentPane.ID,
        fileURL: URL,
        in sessionID: TerminalSession.ID? = nil
    ) -> Bool {
        guard let sessionID = sessionID ?? selectedSessionID,
            let position = position(for: sessionID),
            let session = PaneLayoutReducer.replaceDocumentTab(
                tabID: documentID,
                fileURL: fileURL,
                in: _groups[position.groupIndex].sessions[position.sessionIndex]
            )
        else {
            return false
        }
        _groups[position.groupIndex].sessions[position.sessionIndex] = session
        commit(WorkspaceMutationEffect(needsFullRebuild: true))
        return true
    }

    public func setActivePane(id paneID: TerminalPane.ID, in sessionID: TerminalSession.ID) {
        if let position = position(for: sessionID),
            let session = PaneLayoutReducer.setActivePane(
                id: paneID,
                in: _groups[position.groupIndex].sessions[position.sessionIndex]
            )
        {
            _groups[position.groupIndex].sessions[position.sessionIndex] = session
        }
        // Re-arm the dwell on focus activation even when the pane was already
        // active (e.g. the window regains key on the active pane) so the active
        // pane's notification still gets the read-then-ack treatment rather than
        // the old immediate, guard-bypassing clear (S3).
        rescheduleAcknowledgementIfSelected(sessionID)
    }

    public func focusPane(
        _ direction: PaneFocusDirection,
        in sessionID: TerminalSession.ID? = nil
    ) {
        guard let sessionID = sessionID ?? selectedSessionID,
            let position = position(for: sessionID),
            let session = PaneLayoutReducer.focusPane(
                direction,
                in: _groups[position.groupIndex].sessions[position.sessionIndex]
            )
        else {
            return
        }
        _groups[position.groupIndex].sessions[position.sessionIndex] = session
        rescheduleAcknowledgementIfSelected(sessionID)
    }

    /// Returns `true` only when the active pane actually changed, so callers
    /// (e.g. the VoiceOver announcement) don't signal a move that didn't happen
    /// — the reducer returns nil for an already-active or out-of-range index.
    @discardableResult
    public func focusPane(
        at index: Int,
        in sessionID: TerminalSession.ID? = nil
    ) -> Bool {
        guard let sessionID = sessionID ?? selectedSessionID,
            let position = position(for: sessionID),
            let session = PaneLayoutReducer.focusPane(
                at: index,
                in: _groups[position.groupIndex].sessions[position.sessionIndex]
            )
        else {
            return false
        }
        _groups[position.groupIndex].sessions[position.sessionIndex] = session
        rescheduleAcknowledgementIfSelected(sessionID)
        return true
    }

    /// Re-arms the selection dwell after the active pane changes within the
    /// selected workspace. The dwell acks the ACTIVE pane only (R3), so without
    /// re-baselining on the new active pane the pending dwell would bail and the
    /// new pane would stay loud — and focus/mouse activation that routes through
    /// here gets the same 500ms read guard as a workspace selection (S3).
    private func rescheduleAcknowledgementIfSelected(_ sessionID: TerminalSession.ID) {
        guard sessionID == selectedSessionID else { return }
        scheduleAcknowledgementForSelectedSession()
    }

    public func resizeSplit(
        id splitID: TerminalSplit.ID,
        firstFraction: Double,
        in sessionID: TerminalSession.ID? = nil
    ) {
        guard let sessionID = sessionID ?? selectedSessionID,
            let position = position(for: sessionID),
            let session = PaneLayoutReducer.resizeSplit(
                id: splitID,
                firstFraction: firstFraction,
                in: _groups[position.groupIndex].sessions[position.sessionIndex]
            )
        else {
            return
        }
        _groups[position.groupIndex].sessions[position.sessionIndex] = session
    }

    public func resizeActiveSplit(by delta: Double, in sessionID: TerminalSession.ID? = nil) {
        guard let sessionID = sessionID ?? selectedSessionID,
            let position = position(for: sessionID),
            let session = PaneLayoutReducer.resizeActiveSplit(
                by: delta,
                in: _groups[position.groupIndex].sessions[position.sessionIndex]
            )
        else {
            return
        }
        _groups[position.groupIndex].sessions[position.sessionIndex] = session
    }

    @discardableResult
    public func closeActivePane(in sessionID: TerminalSession.ID? = nil) -> TerminalPane.ID? {
        guard let sessionID = sessionID ?? selectedSessionID,
            let position = position(for: sessionID),
            _groups[position.groupIndex].sessions[position.sessionIndex].layout.hasMultiplePanes,
            case let .pane(closedPaneID) = closePane(
                id: _groups[position.groupIndex].sessions[position.sessionIndex].activePaneID,
                in: sessionID
            )
        else {
            return nil
        }
        return closedPaneID
    }

    @discardableResult
    public func recycleActivePane(in sessionID: TerminalSession.ID? = nil) -> TerminalPane.ID? {
        recycleActivePane(in: sessionID, executionPlan: nil)
    }

    @discardableResult
    public func convertPaneToManagedSSH(
        sessionID: TerminalSession.ID,
        paneID: TerminalPane.ID,
        target: RemoteTarget
    ) -> TerminalPane.ID? {
        guard target.isSafeSSHDestination,
            let pane = session(id: sessionID)?.activePane,
            pane.id == paneID,
            pane.executionPlan == .local
        else {
            return nil
        }
        return recycleActivePane(
            in: sessionID,
            executionPlan: .ssh(SSHExecution(target: target))
        )
    }

    private func recycleActivePane(
        in sessionID: TerminalSession.ID?,
        executionPlan: PaneExecutionPlan?
    ) -> TerminalPane.ID? {
        guard let sessionID = sessionID ?? selectedSessionID,
            let position = position(for: sessionID),
            let result = PaneLayoutReducer.recycleActivePane(
                in: _groups[position.groupIndex].sessions[position.sessionIndex],
                now: Date(),
                executionPlan: executionPlan
            )
        else {
            return nil
        }
        _groups[position.groupIndex].sessions[position.sessionIndex] = result.session
        shellActivityReducer.removeDebounce(paneID: result.discardedPaneID)
        shellActivityReducer.removePromptSeen(paneID: result.discardedPaneID)
        runtimeEventReducer.remove(paneID: result.discardedPaneID)
        // Recycle replaces a pane (a structural change), so full rebuild
        // recomputes unreadNotificationTotal from scratch — no separate unread
        // delta is needed here.
        commit(WorkspaceMutationEffect(needsFullRebuild: true))
        return result.discardedPaneID
    }

    @discardableResult
    public func closePane(
        id paneID: TerminalPane.ID,
        in sessionID: TerminalSession.ID,
        origin: CloseOrigin = .user
    ) -> PaneCloseResult? {
        guard let position = position(for: sessionID),
            let close = PaneLayoutReducer.closePane(
                id: paneID,
                in: _groups[position.groupIndex].sessions[position.sessionIndex]
            )
        else {
            return nil
        }

        switch close.result {
        case .session:
            closeSession(id: sessionID, origin: origin)
        case .pane:
            if let session = close.session {
                _groups[position.groupIndex].sessions[position.sessionIndex] = session
            }
            shellActivityReducer.removePromptSeen(paneID: paneID)
            shellActivityReducer.removeDebounce(paneID: paneID)
            runtimeEventReducer.remove(paneID: paneID)
            commit(WorkspaceMutationEffect(needsFullRebuild: true))
        }

        return close.result
    }

    /// Moves a pane against a workspace edge, reparenting the remaining tree
    /// under a new root split. Returns `true` only when the move actually
    /// happened, so callers can disable a command that would be a no-op.
    @discardableResult
    public func movePane(
        id paneID: TerminalPane.ID,
        toWorkspaceEdge edge: PaneMoveEdge,
        in sessionID: TerminalSession.ID? = nil
    ) -> Bool {
        guard let sessionID = sessionID ?? selectedSessionID,
            let position = position(for: sessionID),
            let session = PaneLayoutReducer.movePane(
                id: paneID,
                toWorkspaceEdge: edge,
                in: _groups[position.groupIndex].sessions[position.sessionIndex]
            )
        else {
            return false
        }
        _groups[position.groupIndex].sessions[position.sessionIndex] = session
        commit(WorkspaceMutationEffect(needsFullRebuild: true))
        return true
    }

    /// Moves a pane onto an edge of another pane, splitting the target in place.
    /// Returns `true` only when the move actually happened.
    @discardableResult
    public func movePane(
        id paneID: TerminalPane.ID,
        adjacentToPane targetID: TerminalPane.ID,
        onEdge edge: PaneMoveEdge,
        in sessionID: TerminalSession.ID? = nil
    ) -> Bool {
        guard let sessionID = sessionID ?? selectedSessionID,
            let position = position(for: sessionID),
            let session = PaneLayoutReducer.movePane(
                id: paneID,
                adjacentToPane: targetID,
                onEdge: edge,
                in: _groups[position.groupIndex].sessions[position.sessionIndex]
            )
        else {
            return false
        }
        _groups[position.groupIndex].sessions[position.sessionIndex] = session
        commit(WorkspaceMutationEffect(needsFullRebuild: true))
        return true
    }

    /// Exchanges two panes' positions, leaving tree shape and fractions intact.
    /// Returns `true` only when the swap actually happened.
    @discardableResult
    public func swapPanes(
        firstID: TerminalPane.ID,
        secondID: TerminalPane.ID,
        in sessionID: TerminalSession.ID? = nil
    ) -> Bool {
        guard let sessionID = sessionID ?? selectedSessionID,
            let position = position(for: sessionID),
            let session = PaneLayoutReducer.swapPanes(
                firstID: firstID,
                secondID: secondID,
                in: _groups[position.groupIndex].sessions[position.sessionIndex]
            )
        else {
            return false
        }
        _groups[position.groupIndex].sessions[position.sessionIndex] = session
        commit(WorkspaceMutationEffect(needsFullRebuild: true))
        return true
    }

    public func canMovePane(
        id paneID: TerminalPane.ID,
        toWorkspaceEdge edge: PaneMoveEdge,
        in sessionID: TerminalSession.ID? = nil
    ) -> Bool {
        guard let sessionID = sessionID ?? selectedSessionID,
            let position = position(for: sessionID)
        else {
            return false
        }
        return PaneLayoutReducer.canMovePane(
            id: paneID,
            toWorkspaceEdge: edge,
            in: _groups[position.groupIndex].sessions[position.sessionIndex]
        )
    }

    public func canMovePane(
        id paneID: TerminalPane.ID,
        adjacentToPane targetID: TerminalPane.ID,
        onEdge edge: PaneMoveEdge,
        in sessionID: TerminalSession.ID? = nil
    ) -> Bool {
        guard let sessionID = sessionID ?? selectedSessionID,
            let position = position(for: sessionID)
        else {
            return false
        }
        return PaneLayoutReducer.canMovePane(
            id: paneID,
            adjacentToPane: targetID,
            onEdge: edge,
            in: _groups[position.groupIndex].sessions[position.sessionIndex]
        )
    }

    public func canSwapPanes(
        firstID: TerminalPane.ID,
        secondID: TerminalPane.ID,
        in sessionID: TerminalSession.ID? = nil
    ) -> Bool {
        guard let sessionID = sessionID ?? selectedSessionID,
            let position = position(for: sessionID)
        else {
            return false
        }
        return PaneLayoutReducer.canSwapPanes(
            firstID: firstID,
            secondID: secondID,
            in: _groups[position.groupIndex].sessions[position.sessionIndex]
        )
    }

    @discardableResult
    public func clearStaleErrorIfPresent(
        id: TerminalSession.ID,
        paneID: TerminalPane.ID? = nil
    ) -> Bool {
        guard let position = position(for: id) else { return false }
        let now = Date()
        let didChange = WorkspaceAttentionReducer.clearStaleErrorIfPresent(
            &_groups[position.groupIndex].sessions[position.sessionIndex],
            paneID: paneID,
            now: now
        )
        if didChange {
            commit(
                WorkspaceMutationEffect(riskSessionIDs: [id]),
                now: now
            )
        }
        return didChange
    }

}
