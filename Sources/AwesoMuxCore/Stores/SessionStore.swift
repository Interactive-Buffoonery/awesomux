import AwesoMuxBridgeProtocol
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
    /// The ONE live-title coalescing window — it gates both the per-tick coarse
    /// publish on a session's `LiveTitleBox` and the `liveTitleGeneration` bump
    /// (`tickLiveTitle`). ~1 Hz: fast enough that a title an agent just set is
    /// searchable before the user finishes typing a query, slow enough that a
    /// 10 Hz spinner cannot drive sidebar-wide re-derivation or row re-layout.
    ///
    /// Measured, not guessed: with the fine channel already carrying the pane
    /// title bars, the residual per-animating-pane cost sat in the sidebar rows.
    /// 1 Hz is where that cost stops registering while the staleness stays
    /// invisible — a name in a sidebar row is not an animation; nobody perceives
    /// "cargo build" arriving a second late. And since issue #327 it is the ONLY
    /// such interval: the coarse mirror used to keep its own constant here so
    /// the two could be tuned independently, and the same value under two names
    /// was still two independently PHASED windows. There is no second drum to
    /// beat against.
    nonisolated public static let defaultLiveTitleGenerationInterval: TimeInterval = 1
    nonisolated public static let maxRecentlyClosed: Int = RecentlyClosedWorkspaceReducer.maxRecentlyClosed
    nonisolated public static let recentlyClosedTTL: TimeInterval = RecentlyClosedWorkspaceReducer.recentlyClosedTTL
    nonisolated public static let appendIndex: Int = .max
    nonisolated public static let shellActivityBusyDebounceInterval: TimeInterval = 0.25
    nonisolated public static let shellActivityIdleDebounceInterval: TimeInterval = 0.10

    @ObservationIgnored private var groupStorage: [SessionGroup]

    // Hand-written stand-in for what @Observable synthesizes for a stored
    // property, so that storage can also be written *without* publishing — see
    // `withSilentGroupMutation` below (issue #311).
    // Same manual-conformance shape as `selectedSessionID`.
    //
    // `get` and `_modify` match the macro expansion. `set` deliberately does
    // NOT: the real macro guards the publish with `shouldNotifyObservers(old,
    // new)`, suppressing a same-value assignment, and this one always
    // publishes. That is safe only because both whole-array call sites
    // (`replaceState`, `updateShellActivity`) already know the value changed
    // before assigning — which makes the guard's O(tree) equality walk pure
    // waste here. **Obligation on any new whole-array assignment: gate it on
    // change yourself, or add the guard.**
    //
    // `_modify` is not optional here: without it Swift falls back to
    // get-modify-writeback, which adds a whole array-buffer copy to every
    // in-place mutation (`_groups[i].sessions[j] = …`) at ~150 call sites.
    var _groups: [SessionGroup] {
        get {
            access(keyPath: \._groups)
            return groupStorage
        }
        set {
            withMutation(keyPath: \._groups) {
                groupStorage = newValue
            }
            refreshLiveTitleBoxes()
        }
        _modify {
            access(keyPath: \._groups)
            _$observationRegistrar.willSet(self, keyPath: \._groups)
            defer {
                _$observationRegistrar.didSet(self, keyPath: \._groups)
                refreshLiveTitleBoxes()
            }
            yield &groupStorage
        }
    }

    /// Mutates group storage in place **without** publishing: no `access`, no
    /// `withMutation`, so no observer of `groups` is woken.
    ///
    /// Exclusively for display-only OSC title writes (issue #311). Storage stays
    /// current, so every consumer that reads `session.title` / `pane.title` off
    /// the struct still sees the new value on its next render — the write simply
    /// stops *being* the thing that schedules that render, which is the whole
    /// point when an agent spinner reports 10 titles/sec.
    ///
    /// The caller must guarantee no observer needs waking for the write it makes
    /// here. `withObservationTracking` cannot catch misuse: to the tracking
    /// machinery a silent write is indistinguishable from no write at all, so a
    /// misclassified publishing write surfaces as a frozen view rather than as a
    /// test failure.
    func withSilentGroupMutation<T>(_ body: (inout [SessionGroup]) -> T) -> T {
        body(&groupStorage)
    }

    /// Per-session live-title channels, created on demand by their consumers
    /// (the views / projections that must track a title tick) and pruned in
    /// `rebuildDerivedState`.
    @ObservationIgnored private var liveTitles: [TerminalSession.ID: LiveTitleBox] = [:]

    /// The `LiveTitleBox` for `sessionID`, seeded from current storage so a
    /// restored pane renders its persisted title rather than sitting blank
    /// until its first OSC report.
    ///
    /// Reads storage directly rather than `session(id:)`: a view that only
    /// wants the box must not pick up a dependency on `groups` on the way in,
    /// which would hand back the per-tick invalidation this channel exists to
    /// remove.
    public func liveTitleBox(for sessionID: TerminalSession.ID) -> LiveTitleBox {
        if let existing = liveTitles[sessionID] {
            return existing
        }
        let box = LiveTitleBox()
        // Bounds- and identity-checked for symmetry with `refreshLiveTitleBoxes`,
        // the other reader of the same index → storage path: both are `public`
        // or `public`-reachable (`LiveTitleScope.body` calls this one), and
        // neither has a way to know whether `commit` has repaired `index` yet.
        // No caller is known to reach here mid-structural-mutation today; an
        // unguarded subscript that only holds because of that is the wrong thing
        // to leave next to a guarded sibling.
        if let session = storedSessionForLiveTitleBox(sessionID) {
            box.adopt(session)
        }
        liveTitles[sessionID] = box
        return box
    }

    /// Storage lookup for a live-title box, bounds- and identity-checked.
    ///
    /// `index` is repaired by `commit`, which runs *after* the write, so
    /// mid-structural-mutation the index can still name a removed session or a
    /// position that has shifted. `reconcileLiveTitleBoxes` corrects the boxes
    /// once the index is rebuilt; until then this returns nil rather than
    /// trapping or adopting a neighbour's title.
    private func storedSessionForLiveTitleBox(
        _ sessionID: TerminalSession.ID
    ) -> TerminalSession? {
        guard let position = index.positionsBySessionID[sessionID],
            groupStorage.indices.contains(position.groupIndex),
            groupStorage[position.groupIndex].sessions.indices.contains(position.sessionIndex)
        else {
            return nil
        }
        let session = groupStorage[position.groupIndex].sessions[position.sessionIndex]
        return session.id == sessionID ? session : nil
    }

    /// One silent title tick's entire downstream effect, run through ONE
    /// per-session coalescing gate.
    ///
    /// When the window has NOT elapsed, only the box's fine-grained properties
    /// move — pane title bars animate per report — and both the coarse mirror
    /// and `liveTitleGeneration` hold. When it HAS, the generation bump and the
    /// coarse publish fire off the SAME timestamp check: the bump re-runs the
    /// bodies that derive search haystacks / duplicate ordinals / rotor labels,
    /// and the boxes those projections resolve titles from published in the same
    /// breath. The two used to drift through independently phased windows on
    /// separate clocks, so a row and the projections beside it could name the
    /// same workspace differently (issue #327, WCAG 4.1.2); one gate makes them
    /// provably in phase.
    ///
    /// The window is stamped before the box publishes, then the generation is
    /// bumped after publication so synchronous observers resolve the new coarse
    /// snapshot. An unrendered session has no box, but the generation still
    /// bumps because sidebar projections cover the whole roster. This never
    /// creates a box: an unobserved session has no one to notify. (`SidebarView`
    /// seeds boxes for the roster via `liveTitleBox(for:)` when building its
    /// resolved-title map — a different path with its own seeding semantics.)
    ///
    /// The narrow counterpart to `refreshLiveTitleBoxes`, for the silent OSC
    /// path, which is the only writer that both knows exactly which pane moved
    /// and runs often enough for the difference to matter.
    func tickLiveTitle(paneID: TerminalPane.ID, in session: TerminalSession, now: Date) {
        // Backwards-clock / non-finite-interval semantics live in the shared
        // check — see `liveTitleCoalescingWindowHasElapsed`.
        let windowHasElapsed = liveTitleCoalescingWindowHasElapsed(
            since: lastLiveTitleBumpBySessionID[session.id],
            now: now,
            interval: liveTitleGenerationInterval
        )
        if windowHasElapsed {
            // Stamp before publishing so a re-entrant write cannot earn the
            // same leading edge. The observable generation itself moves only
            // after the box below has published its complete coarse snapshot.
            lastLiveTitleBumpBySessionID[session.id] = now
        }
        if let box = liveTitles[session.id],
            let pane = session.layout.pane(id: paneID)
        {
            box.adoptPaneTitle(
                pane.id,
                title: pane.title,
                workspaceTitle: session.title,
                publishCoarseNow: windowHasElapsed
            )
        }
        if windowHasElapsed {
            // Last: a synchronous generation observer that resolves titles must
            // see the same coarse snapshot the resulting SwiftUI pass will use.
            liveTitleGeneration += 1
        }
    }

    /// Re-seeds every live box from storage.
    ///
    /// Called from `_groups`' `set` and `_modify` rather than from the mutators
    /// themselves, because "remembered to refresh the box" is exactly the kind
    /// of per-call-site obligation that four of five writers had already
    /// forgotten. A box that shadows storage is worse than no box at all —
    /// `LiveTitles.workspaceTitle(for:)` prefers it over the struct, so a stale
    /// box shows a superseded title *indefinitely*, not for one frame. Hanging
    /// the refresh off the storage accessor makes forgetting impossible: any
    /// write a future mutator makes through `_groups` is covered by
    /// construction.
    ///
    /// Affordable because it rides the PUBLISHING path only — the silent OSC
    /// path bypasses these accessors by design and drives `tickLiveTitle`
    /// instead. A write that reaches here already committed to waking every
    /// `groups` observer (~100 ms of SwiftUI invalidation, issue #311); walking
    /// the roster-bounded set of boxes is noise beside it.
    /// `adopt` is value-guarded, so an unrelated mutation publishes nothing.
    ///
    /// Bounds and identity come from `storedSessionForLiveTitleBox` — see there
    /// for why the index can be wrong at this point.
    ///
    /// Precondition: no observer of a `LiveTitleBox` mutates `_groups`
    /// synchronously from inside its `onChange`. `adopt` publishes while the
    /// enclosing `_groups` write is still on the stack, so such an observer
    /// could land a newer value and refresh the box to it, only for the outer
    /// write to resume and overwrite storage with its own captured session. No
    /// production observer does this — every box consumer is a SwiftUI body that
    /// schedules a render — and the assumption is recorded here rather than
    /// defended in code because the defence (deferring the refresh out of the
    /// accessor) would give back the "a writer forgot" class of bug this
    /// placement exists to remove.
    private func refreshLiveTitleBoxes() {
        guard !liveTitles.isEmpty else { return }
        for (sessionID, box) in liveTitles {
            guard let session = storedSessionForLiveTitleBox(sessionID) else { continue }
            box.adopt(session)
        }
    }

    /// Drops boxes for sessions that no longer exist and re-seeds the survivors
    /// from storage — a bulk restore can reuse a session ID with entirely
    /// different content, and a structural mutation can add or close panes.
    /// Called only from `rebuildDerivedState`, which every structural mutation
    /// already routes through, so no per-callsite cleanup can be missed.
    func reconcileLiveTitleBoxes() {
        // Same lifetime as the boxes, and pruned at the same choke point: the
        // coalescing timestamps are keyed by session ID, so without this a
        // long-lived window that opens and closes workspaces all day accumulates
        // one dead entry per closed workspace forever.
        if !lastLiveTitleBumpBySessionID.isEmpty {
            lastLiveTitleBumpBySessionID = lastLiveTitleBumpBySessionID.filter {
                index.positionsBySessionID[$0.key] != nil
            }
        }
        guard !liveTitles.isEmpty else { return }
        liveTitles = liveTitles.filter { index.positionsBySessionID[$0.key] != nil }
        refreshLiveTitleBoxes()
    }

    /// Coarse "some workspace's displayed title moved" tick for values DERIVED
    /// from titles inside a body that a silent write no longer re-runs — the
    /// sidebar's search haystack, duplicate "N of M" ordinals, VoiceOver rotor
    /// labels, the agent activity panel. Those must not go stale, but they also
    /// do not need to be right within one animation frame, which is what makes
    /// a coarse counter the right currency: one shared counter, so an observer
    /// pays a single invalidation however many workspaces moved.
    ///
    /// Leading-edge on a time check taken at write time — deliberately not a
    /// timer or a debounce task, because coalescing that trails the last write
    /// needs a scheduled wake-up and the repo ratchets against new
    /// sleeps/polling in production (`script/check_test_waits.sh`).
    ///
    /// The counter is shared but the coalescing is **per session** — see
    /// `tickLiveTitle`. Coalescing globally made one workspace's churn able to
    /// swallow another's only title change outright.
    ///
    /// Ceiling — the surviving leading-edge gap, stated exactly: a session's
    /// projections lag when its FINAL event is a display-only title write that
    /// landed less than `liveTitleGenerationInterval` after that same session's
    /// previous bump, and nothing publishes afterwards. "Nothing" is strict: no
    /// attention / unread / agent-state change, no structural mutation, no
    /// selection change, and no later title write by any session (the counter is
    /// shared, so any other session's bump re-derives this one's projections
    /// too). While it holds, the sidebar names that workspace by its previous
    /// title — on the row AND in search AND in the rotor, together. The
    /// projections used to be able to disagree with the row on this; issue #327
    /// killed that by putting both the bump and the coarse publish on this one
    /// gate, so the gap is now a lag the whole sidebar shares, never a split.
    ///
    /// Mitigation, and it is a mitigation rather than a guarantee: an agent that
    /// stops reporting titles is almost always an agent whose state changed, and
    /// attention / unread / agent-state changes all route through `commit`, which
    /// publishes `groups` and re-derives every projection from storage.
    ///
    /// Upgrade path if a lagging projection is ever actually observed: fold the
    /// trailing flush into scheduling that already exists rather than adding a
    /// timer here — `onDisplayOnlyTitleWrite` already kicks the debounced
    /// `SessionPersistence.save`, which is a real trailing edge. Not done now
    /// because that path is gated on the `restoreWorkspaces` setting, and render
    /// correctness must not depend on whether the user persists sessions.
    public internal(set) var liveTitleGeneration: Int = 0

    @ObservationIgnored private let liveTitleGenerationInterval: TimeInterval
    /// Leading-edge coalescing timestamps, keyed by session.
    ///
    /// One shared timestamp cross-suppressed unrelated workspaces: a workspace
    /// whose agent spins at 10 Hz kept the store permanently "not due", so a
    /// second workspace's single title change never bumped the counter and its
    /// derived projections never re-ran. Pruned in `reconcileLiveTitleBoxes`.
    ///
    /// Cost of the split: N spinning workspaces can bump N times per interval
    /// instead of once. Bounded by the number of workspaces reporting titles,
    /// and the alternative is a workspace that search cannot find by its own
    /// displayed name.
    @ObservationIgnored private var lastLiveTitleBumpBySessionID: [TerminalSession.ID: Date] = [:]

    /// One resolved sidebar title per roster session.
    ///
    /// Every sidebar surface that names a workspace must resolve from HERE, not
    /// from `groups` storage: the sidebar row renders the `LiveTitleBox`
    /// coarse mirror, and issue #327 exists because the derived surfaces used
    /// to read the fresher struct title on a different clock and name the same
    /// workspace differently (WCAG 4.1.2). A value is the session's box coarse
    /// title re-run through `TerminalSession.displayTitle(overridingRawTitle:)`,
    /// which preserves the synthetic-title localization path.
    ///
    /// Reads storage directly (like `liveTitleBox(for:)`), so a view that only
    /// wants the map does not pick up a `groups` dependency on the way in. For
    /// a session with no live box yet — one whose row has never rendered —
    /// `liveTitleBox(for:)` creates and seeds the box from storage, so the map
    /// says "coarse" and means "current storage" for unrendered sessions too.
    /// A box that genuinely holds nothing (created mid-structural-mutation,
    /// before any adopt — see `storedSessionForLiveTitleBox`) resolves to the
    /// session's own display title rather than the empty string.
    public func sidebarResolvedTitles(
        bundle: Bundle = .main,
        locale: Locale = .current
    ) -> [TerminalSession.ID: String] {
        var titles: [TerminalSession.ID: String] = [:]
        titles.reserveCapacity(index.positionsBySessionID.count)
        for group in groupStorage {
            for session in group.sessions {
                titles[session.id] = sidebarResolvedTitle(
                    for: session,
                    bundle: bundle,
                    locale: locale
                )
            }
        }
        return titles
    }

    /// Resolves one session without building the roster-wide title map.
    /// Action surfaces use this when they only need the selected workspace.
    public func sidebarResolvedTitle(
        for sessionID: TerminalSession.ID,
        bundle: Bundle = .main,
        locale: Locale = .current
    ) -> String? {
        guard let session = storedSessionForLiveTitleBox(sessionID) else { return nil }
        return sidebarResolvedTitle(for: session, bundle: bundle, locale: locale)
    }

    private func sidebarResolvedTitle(
        for session: TerminalSession,
        bundle: Bundle,
        locale: Locale
    ) -> String {
        let box = liveTitleBox(for: session.id)
        // The flag gates, so the title cannot be nil here; `?? ""` keeps the
        // override's non-optional contract that an empty coarse title is a
        // valid snapshot (issue #329).
        return box.hasCoarseSnapshot
            ? session.displayTitle(
                bundle: bundle,
                locale: locale,
                overridingRawTitle: box.coarseWorkspaceTitle ?? ""
            )
            : session.displayTitle(bundle: bundle, locale: locale)
    }

    /// Called after a display-only title write has landed silently, so the app
    /// can schedule the session save that the suppressed `groups` publish would
    /// otherwise have triggered. Without it a title-only change would schedule
    /// no save at all, widening the crash-loss window to "until the next
    /// unrelated publish" — which, for a workspace running an agent, is
    /// minutes. Clean quit is unaffected: `SessionPersistence.flush`
    /// re-snapshots unconditionally.
    ///
    /// A plain callback and not an `@Observable` property: an observable bump
    /// would wake the Scene body at the title throttle rate (~4×/sec, #306),
    /// reintroducing exactly the app-wide invalidation issue #311 exists to
    /// remove. That is also why it needs no coalescing here — the handler's
    /// `SessionPersistence.save` already cancels and re-debounces its pending
    /// write, so the per-call cost is one COW snapshot and no view work.
    @ObservationIgnored public var onDisplayOnlyTitleWrite: (@MainActor () -> Void)?

    /// Ordered pin list for the sidebar's synthetic Pinned section. Membership
    /// = pinned, array order = display order. Sessions stay inside their
    /// origin group; this is a render-time projection input, never a move
    /// (INT-737).
    ///
    /// Pinned wins over lifted, so every pin membership change is also a lifted
    /// membership change. Reconciling from the observer rather than from
    /// `togglePin` keeps that coupling structural — a future pin mutator cannot
    /// forget it.
    public internal(set) var pinnedSessionIDs: [TerminalSession.ID] = [] {
        didSet { reconcileLiftedSessionIDs() }
    }

    /// Ordered lifted list for the sidebar's synthetic Needs Input section.
    /// Membership = lifted and not pinned, array order = ARRIVAL order: first to
    /// ask sits at the top and new arrivals append at the bottom, so an existing
    /// row is never shoved down under the user's pointer. Re-asking while
    /// already listed does not move a row — it has been waiting longest.
    ///
    /// Same shape as `pinnedSessionIDs`, except auto-maintained rather than
    /// user-curated: `reconcileLiftedSessionIDs()` owns every write.
    /// Runtime-only; arrival order is not persisted (a relaunch rebuilds it in
    /// group order from the two attention reasons `SessionRestoreReducer` keeps).
    public internal(set) var liftedSessionIDs: [TerminalSession.ID] = []

    /// Panes whose finished turn has gone unanswered long enough that the agent
    /// reported the user is away — Claude Code's `idle_prompt`, which fires once,
    /// 60s after a turn-end `Stop` nobody replied to.
    ///
    /// Deliberately NOT an `AttentionReason`. A reason projects to the peach
    /// `.needsAttention` for every user, opens the macOS notification channel,
    /// and makes `AgentPromptGate` treat the pane as unreceptive — none of which
    /// this signal wants. It only decides whether a row lifts, so it lives here,
    /// beside the lift state it feeds, and touches nothing else.
    ///
    /// Runtime-only, like `liftedSessionIDs` arrival order: a relaunch has no
    /// live agent to re-report idleness, so a restored workspace waits for its
    /// next real turn.
    ///
    /// Keyed by pane, VALUED by the provider session that went unanswered,
    /// because a pane is not one conversation. A nested same-kind agent — a
    /// `claude` invoked as a tool call inside a Claude Code pane — inherits the
    /// pane's event file and submits its own prompts through it. The reducer
    /// accepts those (its cross-provider guard only rejects a different
    /// `AgentKind`), so a pane-only mark would let the child's first prompt
    /// retract the parent's still-unanswered turn, permanently: `idle_prompt`
    /// fires at most once per turn.
    ///
    /// The value is optional because not every provider reports a session id.
    /// ponytail: a dictionary because identity is the whole model now; if a
    /// future escalation needs "how long has it been waiting", widen the value
    /// to a struct carrying the timestamp too.
    var unansweredTurns: [TerminalPane.ID: String?] = [:]

    /// Membership only — what the lift predicate needs. Hoist it into a local
    /// before any loop: this allocates a fresh `Set` per read.
    public var unansweredTurnPaneIDs: Set<TerminalPane.ID> { Set(unansweredTurns.keys) }

    /// Mirrored from `appearance.promote_workspaces_needing_input` by
    /// `SidebarView` — the section's only renderer — so the sidebar, the ⌘-jump
    /// order, and the Dock menu resolve the lifted set from one place. Off means
    /// `liftedSessionIDs` is always empty and no sticky is ever captured.
    ///
    /// Refreshes the sticky on write: the sidebar mirrors the setting on appear,
    /// so this is also what arms the sticky at launch, and toggling the setting
    /// off has to drop a sticky the section no longer renders.
    public var needsInputSectionEnabled: Bool = false {
        didSet {
            // Every other path that forcibly ends a "user is reading this row"
            // state cancels the dwell first; this one has to as well, or an
            // in-flight dwell fires against a section that no longer renders.
            acknowledgementCoordinator.cancel()
            refreshAttentionSticky()
        }
    }

    /// The workspace held in the Needs Input section past the point it stopped
    /// needing input. Written synchronously by the `selectedSessionID` setter —
    /// a view-local `@State` written in `.onChange` would lag the body that
    /// reads it, demoting a just-clicked row for one render pass.
    /// Runtime-only; never persisted.
    public internal(set) var attentionStickySessionID: TerminalSession.ID?

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
            // No `refreshAttentionSticky()` here on purpose: it is the first
            // statement of `scheduleAcknowledgementForSelectedSession()`, so the
            // sticky is still refreshed synchronously before this setter returns
            // and before any observer can re-render. Calling it here too would
            // repeat reconcile's O(sessions) walk on every selection change.
            scheduleAcknowledgementForSelectedSession()
        }
    }

    /// Releasing the previous sticky here is what lets an acknowledged workspace
    /// fall back to its group once the user navigates away.
    ///
    /// Called from `scheduleAcknowledgementForSelectedSession()`, the choke point
    /// every dwell-arming path routes through — including the `selectedSessionID`
    /// setter, which reaches it synchronously rather than calling here itself. A
    /// workspace can become needy while already selected, so selection changes
    /// alone would not cover every case where a dwell is about to acknowledge a
    /// row the user is reading.
    func refreshAttentionSticky() {
        guard needsInputSectionEnabled,
            let selected = storedSelectedSessionID,
            !pinnedSessionIDs.contains(selected),
            let session = session(id: selected),
            session.needsUserInput
        else {
            // @Observable publishes even a nil→nil write, and this runs on every
            // dwell arm — invalidating every sidebar row for a no-op.
            if attentionStickySessionID != nil {
                attentionStickySessionID = nil
            }
            reconcileLiftedSessionIDs()
            return
        }
        // Same publish hazard as the nil branch above: a selected, needy
        // workspace re-arms the dwell on every setActivePane / focusPane /
        // window-key change, republishing an identical sticky.
        if attentionStickySessionID != selected {
            attentionStickySessionID = selected
        }
        reconcileLiftedSessionIDs()
    }

    /// Records or retracts a pane's unanswered-turn mark from a runtime event
    /// the reducer already accepted, and reconciles when membership moved.
    ///
    /// The retraction set is deliberately narrow. `.promptSubmit` means a prompt
    /// was actually submitted into this pane — the one phase that proves the turn
    /// got answered, whether the user typed it or `amx send` injected it. Tool
    /// phases are excluded on purpose: subagent tool calls inherit the pane's
    /// event file, and `AgentRuntimeEventReducer` measured a background
    /// `.toolStart` landing after turn-end at 11 of 32 turn-ends in a real trace.
    /// Clearing on those would drop the row out of Needs Input a third of the
    /// time while the agent is still genuinely waiting.
    func updateUnansweredTurn(paneID: TerminalPane.ID, event: AgentRuntimeEvent) {
        let before = unansweredTurns
        switch event.phase {
        case .notification where event.assertsWaitingExecutionState:
            // The only mapping that asserts `.waiting` on a notification is
            // Claude Code's `idle_prompt`. Every other provider's notification
            // carries an attention reason and no execution claim.
            unansweredTurns[paneID] = event.providerSessionID
        case .promptSubmit, .sessionEnd:
            guard retracts(event, markedFor: paneID) else { return }
            unansweredTurns.removeValue(forKey: paneID)
        default:
            return
        }
        guard unansweredTurns.keys != before.keys else { return }
        reconcileLiftedSessionIDs()
    }

    /// Whether an end-of-conversation event belongs to the session that actually
    /// went unanswered.
    ///
    /// Conservative in the direction that matters. Only a PROVEN mismatch — both
    /// sides carrying an id, and disagreeing — refuses to retract, because that
    /// is the one shape a nested child produces. An absent id on either side
    /// retracts as before: providers that report no id at all would otherwise
    /// strand every row they ever lift, which is a worse failure than the
    /// narrow one this guards.
    private func retracts(_ event: AgentRuntimeEvent, markedFor paneID: TerminalPane.ID) -> Bool {
        guard let marked = unansweredTurns[paneID] ?? nil,
            let reported = event.providerSessionID
        else {
            return true
        }
        return marked.caseInsensitiveCompare(reported) == .orderedSame
    }

    /// Drops a pane's unanswered mark and reconciles. Used by the acknowledge
    /// paths, so ⌘⇧K silences a lifted row the same way it silences an attention
    /// reason — otherwise the one escape hatch the section documents would not
    /// reach rows lifted by this signal.
    func clearUnansweredTurn(paneIDs: some Sequence<TerminalPane.ID>) {
        let before = unansweredTurns.count
        for paneID in paneIDs {
            unansweredTurns.removeValue(forKey: paneID)
        }
        guard unansweredTurns.count != before else { return }
        reconcileLiftedSessionIDs()
    }

    /// Sole writer of `liftedSessionIDs`. Every input the lift predicate reads
    /// has a call site that covers it — `commit(_:now:)` for `_groups`,
    /// `refreshAttentionSticky()` for the sticky, and `pinnedSessionIDs`'
    /// observer for pins — but that is coverage per kind of input, not an
    /// invocation count: a selection-changing `commit` reconciles twice (once
    /// from `commit`, once via the sticky refresh the selection cascade reaches).
    /// Keep it cheap and idempotent rather than trying to make it run exactly
    /// once; `commit`'s own call is load-bearing for commits that re-set the
    /// same selection, where the setter cascade never fires.
    ///
    /// Order is the whole point. IDs already listed keep their slots, so a
    /// workspace whose unread goes 1 → 2 does not jump the queue and a new
    /// arrival can never insert above a row the user is about to click.
    /// Newcomers append in group order, which keeps a batch deterministic.
    func reconcileLiftedSessionIDs() {
        guard needsInputSectionEnabled else {
            if !liftedSessionIDs.isEmpty {
                liftedSessionIDs = []
            }
            return
        }
        let pinned = Set(pinnedSessionIDs)
        let sticky = attentionStickySessionID
        // Hoisted: the property builds a fresh `Set` on every read, and this
        // loop runs once per session on a path that fires on every commit.
        let unanswered = unansweredTurnPaneIDs
        var arrivals: [TerminalSession.ID] = []
        var arrivalSet: Set<TerminalSession.ID> = []
        for group in _groups {
            for session in group.sessions
            where !pinned.contains(session.id)
                && SidebarAttentionProjection.isLifted(
                    session,
                    stickySessionID: sticky,
                    unansweredTurnPaneIDs: unanswered
                )
            {
                arrivals.append(session.id)
                arrivalSet.insert(session.id)
            }
        }
        // Drops IDs that were acknowledged, closed, or pinned; the filter also
        // preserves the surviving IDs' relative order for free.
        var next = liftedSessionIDs.filter { arrivalSet.contains($0) }
        let held = Set(next)
        next.append(contentsOf: arrivals.lazy.filter { !held.contains($0) })
        // @Observable publishes on every set, and this runs on every commit.
        guard next != liftedSessionIDs else { return }
        liftedSessionIDs = next
    }

    public internal(set) var unreadNotificationTotal: Int = 0
    public internal(set) var recentlyClosed: [RecentlyClosedWorkspace] = []
    public internal(set) var lastClosedTransient: RecentlyClosedWorkspace?

    public init(
        groups: [SessionGroup] = [],
        selectedSessionID: TerminalSession.ID? = nil,
        recentlyClosed: [RecentlyClosedWorkspace] = [],
        pinnedSessionIDs: [TerminalSession.ID] = [],
        acknowledgementDwellNanoseconds: UInt64 = SessionStore.defaultAcknowledgementDwellNanoseconds,
        liveTitleGenerationInterval: TimeInterval = SessionStore.defaultLiveTitleGenerationInterval
    ) {
        // Through storage, not the computed `_groups`: its setter calls
        // `withMutation` on a not-yet-initialized `self`.
        self.groupStorage = groups
        self.storedSelectedSessionID = selectedSessionID ?? groups.first?.sessions.first?.id
        self.recentlyClosed = recentlyClosed
        self.liveTitleGenerationInterval = liveTitleGenerationInterval
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
        // Same ID-reuse hazard as the undo registrations above, applied to the
        // live-title coalescing stamps. `reconcileLiveTitleBoxes` prunes this
        // map by surviving ID, so a restore that reuses an ID would hand the new
        // content the previous occupant's window: the restored pane's FIRST
        // title report would then be suppressed by a window the user's previous
        // session opened — and if it were that pane's only report, the sidebar
        // would name the workspace by its restored-at title indefinitely.
        //
        // The boxes themselves are deliberately kept: `bulkRestoreRefreshesBoxes`
        // pins that a box held across a restore lands current, and the `_groups`
        // write below re-seeds every survivor through `adopt`. Only the window —
        // which lives here, and nowhere else since issue #327 made it the one
        // clock for both the coarse mirror and the generation — is a new
        // lifetime.
        lastLiveTitleBumpBySessionID.removeAll()
        _groups = components.groups
        recentlyClosed = components.recentlyClosed
        // Both clears precede the `pinnedSessionIDs` write below, whose observer
        // reconciles the lifted list against the new `_groups`: leaving them
        // after it would make the end state depend on the commit that follows
        // rather than on the clears themselves.
        //
        // "The user is mid-read of this row" is not state a bulk restore
        // inherits, and the ID-reuse hazard above applies: a surviving sticky
        // could lift a restored workspace that never needed input.
        attentionStickySessionID = nil
        // Same ID-reuse hazard: a surviving arrival order would seat restored
        // workspaces by when their pre-restore namesakes asked. The commit below
        // rebuilds it in group order.
        liftedSessionIDs = []
        // Same ID-reuse hazard as the sticky above: a surviving unanswered mark
        // could lift a restored workspace whose pane never went unanswered. The
        // live agent, if any, re-reports on its next idle prompt.
        unansweredTurns = [:]
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
        toGroupID groupID: SessionGroup.ID,
        sessionName: RemoteSessionName? = nil
    ) -> TerminalSession.ID? {
        let execution = Self.sshExecution(target: target, sessionName: sessionName)
        guard
            let sessionID = WorkspaceTreeReducer.addSession(
                to: &_groups,
                selectedSession: selectedSession,
                title: nil,
                workingDirectory: nil,
                groupID: groupID,
                executionPlan: .ssh(execution)
            )
        else { return nil }
        commit(WorkspaceMutationEffect(needsFullRebuild: true, selection: .set(sessionID)))
        return sessionID
    }

    @discardableResult
    public func addLocalSession(
        title: String?,
        workingDirectory: String,
        toGroupID groupID: SessionGroup.ID
    ) -> TerminalSession.ID? {
        guard
            let sessionID = WorkspaceTreeReducer.addSession(
                to: &_groups,
                selectedSession: selectedSession,
                title: title,
                workingDirectory: workingDirectory,
                groupID: groupID,
                executionPlan: .local
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
    ///
    /// - Parameter releasesAttentionSticky: `false` only for the passive
    ///   selection dwell, which must NOT evict the row the user is reading. Every
    ///   deliberate gesture (context menu, ⌘⇧K, Clear All Notifications) leaves
    ///   the default so the row leaves the section immediately.
    /// - Parameter answersUnansweredTurn: whether this gesture proves the user
    ///   answered the turn, as opposed to merely reaching or reading the pane.
    ///   Independent of `releasesAttentionSticky`: the ack-on-read dwell passes
    ///   false to both, the peek-card and roster pane jumps release the sticky
    ///   but do NOT answer anything, and only a deliberate acknowledge is both.
    public func acknowledgeSession(
        id: TerminalSession.ID,
        releasesAttentionSticky: Bool = true,
        answersUnansweredTurn: Bool = true
    ) {
        guard let position = position(for: id) else { return }
        if id == selectedSessionID {
            acknowledgementCoordinator.cancel()
        }
        if releasesAttentionSticky, attentionStickySessionID == id {
            attentionStickySessionID = nil
        }
        let activePaneID = _groups[position.groupIndex]
            .sessions[position.sessionIndex].activePaneID
        let change = WorkspaceAttentionReducer.acknowledgePane(
            &_groups[position.groupIndex].sessions[position.sessionIndex],
            paneID: activePaneID
        )
        // Ack-on-read must not reach this mark, on any surface. The dwell's own
        // body already refuses to passively clear a BLOCKING `awaitsExplicitAnswer`
        // prompt, but that guard reads `attentionReason`, and an idle prompt
        // deliberately sets none — so it never covered this signal, which is why
        // the bug existed. The rule is the same either way: reading a finished
        // turn is not answering it. It bites harder here, because `idle_prompt`
        // fires at most once per turn, so a passive clear retires the signal for
        // good. Verified against a live build: the selected workspace was the
        // one workspace this signal could not reach.
        //
        // The jump surfaces are the same rule seen from the other side. Landing
        // on a waiting pane from the peek card or the activity roster is arrival,
        // not an answer — and the roster's whole workflow is cycling through
        // waiting panes to survey them, which would otherwise wipe every mark it
        // visited. They still ack the unread badge, which IS ack-on-read's proper
        // subject: seeing a bell is the whole response to a bell.
        if answersUnansweredTurn {
            clearUnansweredTurn(paneIDs: [activePaneID])
        }
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
        if attentionStickySessionID == id {
            attentionStickySessionID = nil
        }
        let change = WorkspaceAttentionReducer.acknowledgeAllPanes(
            in: &_groups[position.groupIndex].sessions[position.sessionIndex]
        )
        clearUnansweredTurn(
            paneIDs: _groups[position.groupIndex].sessions[position.sessionIndex].panes.map(\.id)
        )
        commit(WorkspaceMutationEffect(unreadChange: change))
    }

    public func acknowledgeAllSessions() {
        acknowledgementCoordinator.cancel()
        attentionStickySessionID = nil
        // The widest acknowledge sweep has to reach the widest silence. The
        // full rebuild below only prunes marks whose pane is GONE, so without
        // this every live marked pane stays lifted after "acknowledge
        // everything" — the one action that promises an empty section.
        unansweredTurns.removeAll()
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
    /// its entry before restoring the session), so skipping capture is the
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
    /// reopened" promise. At most one entry per tier matches a sessionID (reopen
    /// drains before restore), so forget-by-sessionID clears the whole match.
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
    /// `removeGroup` refuses a still-populated group. Closing the sole group
    /// is allowed and leaves an empty tree — the cold-launch state, which
    /// `SessionDetailView` renders as its first-launch empty state.
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
    /// non-empty groups, and callers announcing the outcome must not claim a
    /// removal that was silently refused.
    @discardableResult
    public func removeGroup(id: SessionGroup.ID) -> Bool {
        // Captured before the reducer runs: closing an EMPTY group takes
        // neither confirmation branch (nothing live to warn about), so undo is
        // the only recovery a mis-click has.
        guard let removedIndex = _groups.firstIndex(where: { $0.id == id }) else { return false }
        let removed = _groups[removedIndex]
        guard WorkspaceTreeReducer.removeGroup(in: &_groups, id: id) else { return false }
        commit(WorkspaceMutationEffect(needsFullRebuild: true))
        registerUndo(actionName: Self.closeGroupUndoActionName) { target in
            target.restoreRemovedGroup(removed, at: removedIndex)
        }
        return true
    }

    private static let closeGroupUndoActionName = String(
        localized: "Close Group",
        comment: "Undo action for closing a workspace group."
    )

    /// Undo inverse for `removeGroup`. Reinstates the removed VALUE, not a
    /// fresh group with the same name — `SessionGroup` also carries the color
    /// and the SSH creation default, and a rebuilt stand-in would silently drop
    /// both. `removeGroup` only ever removes an empty group, so there are no
    /// sessions to collide with on the way back in.
    ///
    /// ponytail: workspaces closed by `closeGroup` are NOT part of this — they
    /// leave through `closeSession`, whose recovery path is Reopen Closed
    /// Workspace (⌘⇧T). Undoing that close returns the group shell to reopen
    /// them into.
    private func restoreRemovedGroup(_ group: SessionGroup, at index: Int) {
        // A group with this ID already back (redo of a redo, or a restore that
        // reused the ID) makes this inverse stale — refuse rather than
        // duplicate, and register nothing so no redo is offered for a no-op.
        guard !_groups.contains(where: { $0.id == group.id }) else { return }
        _groups.insert(group, at: min(index, _groups.count))
        commit(WorkspaceMutationEffect(needsFullRebuild: true))
        registerUndo(actionName: Self.closeGroupUndoActionName) { target in
            target.removeGroup(id: group.id)
        }
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
            // ponytail: the restore index is the captured source index, clamped
            // by the reducer. If a non-undoable close shifts positions before
            // undo, the workspace lands near — not exactly at — its old slot.
            // ID-anchored ordering would fix that at the cost of a bespoke
            // ordering model; revisit only if drift shows up in practice.
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
            // ponytail: sourceIndex is the captured original index, clamped by
            // the reducer — same near-not-exact ceiling as the moveSession
            // inverse when a non-undoable close shifted positions in between.
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
        // Pinned wins over lifted by construction, so a surviving sticky would
        // hijack the tile back into Needs Input the moment it is unpinned.
        if attentionStickySessionID == sessionID {
            attentionStickySessionID = nil
        }
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
        agentTranscriptIdentity: AgentTranscriptIdentity? = nil,
        branchChangesIdentity: BranchChangesIdentity? = nil,
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
                agentTranscriptIdentity: agentTranscriptIdentity,
                branchChangesIdentity: branchChangesIdentity,
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
        target: RemoteTarget,
        sessionName: RemoteSessionName? = nil
    ) -> TerminalPane.ID? {
        guard let pane = session(id: sessionID)?.activePane,
            pane.id == paneID,
            pane.executionPlan == .local
        else {
            return nil
        }
        return recycleActivePane(
            in: sessionID,
            executionPlan: .ssh(Self.sshExecution(target: target, sessionName: sessionName))
        )
    }

    /// A named session is remote-owned; an unnamed one is the local-amx default.
    /// Non-optional deliberately: both arms satisfy `SSHExecution`'s invariant
    /// by construction, so an Optional here would be a nil case no caller could
    /// ever reach — the failable init still earns its `?` at the decode seam,
    /// where the input is untrusted JSON rather than these two branches.
    private static func sshExecution(
        target: RemoteTarget,
        sessionName: RemoteSessionName?
    ) -> SSHExecution {
        guard let sessionName else {
            return SSHExecution(target: target)
        }
        return SSHExecution(target: target, remoteSessionName: sessionName)
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

    public func canMovePaneToNewWorkspace(
        id paneID: TerminalPane.ID,
        in sessionID: TerminalSession.ID
    ) -> Bool {
        guard let position = position(for: sessionID) else { return false }
        return PaneLayoutReducer.movePaneToNewWorkspace(
            id: paneID,
            from: _groups[position.groupIndex].sessions[position.sessionIndex]
        ) != nil
    }

    @discardableResult
    public func movePaneToNewWorkspace(
        id paneID: TerminalPane.ID,
        in sessionID: TerminalSession.ID
    ) -> TerminalSession.ID? {
        guard let position = position(for: sessionID),
            let result = PaneLayoutReducer.movePaneToNewWorkspace(
                id: paneID,
                from: _groups[position.groupIndex].sessions[position.sessionIndex]
            )
        else {
            return nil
        }

        // Insert before rewriting the source: the insert lands after the source
        // row, so the source index is unchanged, and a refused insert leaves
        // the pane where it was instead of removed from both workspaces.
        guard WorkspaceTreeReducer.insertSession(result.moved, after: sessionID, into: &_groups)
        else { return nil }
        _groups[position.groupIndex].sessions[position.sessionIndex] = result.source
        // Document tabs associated with the moved pane deliberately stay in
        // the source with a stale association. `documentSendTarget` fails
        // closed, and `openDocumentPane` re-associates opportunistically when
        // the document is reopened; this move does not change that policy.
        // After the groups write: the rebuild prunes pins to live sessions.
        if pinnedSessionIDs.contains(sessionID) {
            let insertionIndex =
                pinnedSessionIDs.firstIndex(of: sessionID).map { $0 + 1 }
                ?? pinnedSessionIDs.endIndex
            // Pinned rows render in this array's order, so inherit directly
            // beneath the source instead of jumping to the section's end.
            pinnedSessionIDs.insert(result.moved.id, at: insertionIndex)
        }
        commit(
            WorkspaceMutationEffect(
                needsFullRebuild: true,
                selection: .set(result.moved.id)
            ))
        return result.moved.id
    }

    public func canReturnPaneToSourceWorkspace(sessionID: TerminalSession.ID) -> Bool {
        guard let movedPosition = position(for: sessionID),
            let origin = _groups[movedPosition.groupIndex].sessions[movedPosition.sessionIndex].moveOrigin,
            origin.sourceSessionID != sessionID,
            let sourcePosition = position(for: origin.sourceSessionID),
            sourcePosition != movedPosition
        else {
            return false
        }
        return PaneLayoutReducer.returnPane(
            from: _groups[movedPosition.groupIndex].sessions[movedPosition.sessionIndex],
            to: _groups[sourcePosition.groupIndex].sessions[sourcePosition.sessionIndex]
        ) != nil
    }

    public func returnPaneToSourceWorkspace(sessionID: TerminalSession.ID) -> Bool {
        guard let movedPosition = position(for: sessionID) else { return false }
        let moved = _groups[movedPosition.groupIndex].sessions[movedPosition.sessionIndex]
        guard let origin = moved.moveOrigin,
            origin.sourceSessionID != sessionID,
            let sourcePosition = position(for: origin.sourceSessionID),
            sourcePosition != movedPosition,
            let source = PaneLayoutReducer.returnPane(
                from: moved,
                to: _groups[sourcePosition.groupIndex].sessions[sourcePosition.sessionIndex],
                parentSplitIDIsLive: _groups.contains { group in
                    group.sessions.contains { $0.id != sessionID && $0.layout.split(id: origin.parentSplitID) != nil }
                }
            )
        else {
            return false
        }

        _groups[sourcePosition.groupIndex].sessions[sourcePosition.sessionIndex] = source
        // Not `closeSession`: that records a recently-closed entry and wipes
        // pane-keyed runtime state for a pane that is still alive in the source.
        _groups[movedPosition.groupIndex].sessions.remove(at: movedPosition.sessionIndex)
        commit(
            WorkspaceMutationEffect(
                needsFullRebuild: true,
                selection: .set(origin.sourceSessionID)
            ))
        return true
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
