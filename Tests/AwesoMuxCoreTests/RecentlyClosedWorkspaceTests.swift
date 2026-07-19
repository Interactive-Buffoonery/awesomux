import Foundation
import Testing
@testable import AwesoMuxCore

@MainActor
@Suite("RecentlyClosedWorkspace — capture, persistence, reopen")
struct RecentlyClosedWorkspaceTests {

    // MARK: - Helpers

    private static func makeStore(
        sessionCount: Int = 1,
        groupName: String = "awesoMux"
    ) -> SessionStore {
        var sessions: [TerminalSession] = []
        for index in 0..<sessionCount {
            sessions.append(
                TerminalSession(
                    title: "ws-\(index)",
                    workingDirectory: NSHomeDirectory(),
                    isTitleUserEdited: true,
                    agentKind: .shell,
                    agentState: .idle
                ))
        }
        let group = SessionGroup(name: groupName, sessions: sessions)
        let store = SessionStore(groups: [group])
        store.selectedSessionID = sessions.first?.id
        return store
    }

    // MARK: - Capture path

    @Test("closing a workspace pushes a snapshot to recentlyClosed")
    func captureOnClose() throws {
        let store = Self.makeStore(sessionCount: 1)
        let session = try #require(store.selectedSession)
        let originalID = session.id

        #expect(store.recentlyClosed.isEmpty)
        store.closeSession(id: session.id)
        #expect(store.recentlyClosed.count == 1)

        let entry = try #require(store.recentlyClosed.first)
        #expect(entry.sessionID == originalID)
        #expect(entry.title == "ws-0")
        #expect(entry.isTitleUserEdited == true)
        #expect(entry.agentKind == .shell)
        #expect(entry.indexInGroup == 0)
    }

    @Test("rapid closes land in LIFO order — most recent at head")
    func lifoOrdering() throws {
        let store = Self.makeStore(sessionCount: 3)
        let ids = store.groups[0].sessions.map(\.id)

        store.closeSession(id: ids[0])
        store.closeSession(id: ids[1])
        store.closeSession(id: ids[2])

        #expect(store.recentlyClosed.count == 3)
        #expect(store.recentlyClosed[0].sessionID == ids[2])
        #expect(store.recentlyClosed[1].sessionID == ids[1])
        #expect(store.recentlyClosed[2].sessionID == ids[0])
    }

    @Test("buffer evicts the oldest entry at the cap")
    func capEnforcement() throws {
        let store = Self.makeStore(sessionCount: SessionStore.maxRecentlyClosed + 5)
        let ids = store.groups[0].sessions.map(\.id)

        for id in ids {
            store.closeSession(id: id)
        }

        #expect(store.recentlyClosed.count == SessionStore.maxRecentlyClosed)
        // The 5 oldest entries (ids[0..<5]) should have been evicted.
        let retainedSessionIDs = Set(store.recentlyClosed.map(\.sessionID))
        #expect(!retainedSessionIDs.contains(ids[0]))
        #expect(!retainedSessionIDs.contains(ids[4]))
        #expect(retainedSessionIDs.contains(ids[5]))
        #expect(retainedSessionIDs.contains(ids.last!))
    }

    // MARK: - TTL

    @Test("entries older than the TTL are pruned at restore time")
    func pruneOnRestore() throws {
        let stale = RecentlyClosedWorkspace(
            sessionID: UUID(),
            title: "stale",
            isTitleUserEdited: false,
            agentKind: .shell,
            layout: .pane(TerminalPane(title: "stale", workingDirectory: NSHomeDirectory(), executionPlan: .local)),
            activePaneID: UUID(),
            groupID: UUID(),
            groupName: "ghost-group",
            groupRemote: nil,
            indexInGroup: 0,
            closedAt: Date().addingTimeInterval(-(SessionStore.recentlyClosedTTL + 60))
        )
        let fresh = RecentlyClosedWorkspace(
            sessionID: UUID(),
            title: "fresh",
            isTitleUserEdited: false,
            agentKind: .shell,
            layout: .pane(TerminalPane(title: "fresh", workingDirectory: NSHomeDirectory(), executionPlan: .local)),
            activePaneID: UUID(),
            groupID: UUID(),
            groupName: "live-group",
            groupRemote: nil,
            indexInGroup: 0,
            closedAt: Date()
        )

        let snapshot = SessionSnapshot(
            groups: [SessionGroup(name: "g", sessions: [])],
            selectedSessionID: nil,
            recentlyClosed: [fresh, stale]
        )
        let store = SessionStore(restoring: snapshot)

        #expect(store.recentlyClosed.count == 1)
        #expect(store.recentlyClosed.first?.title == "fresh")
    }

    @Test("snapshot() filters expired entries so lazy pruning never re-persists them")
    func snapshotFiltersExpired() throws {
        let stale = RecentlyClosedWorkspace(
            sessionID: UUID(),
            title: "stale",
            isTitleUserEdited: false,
            agentKind: .shell,
            layout: .pane(TerminalPane(title: "stale", workingDirectory: NSHomeDirectory(), executionPlan: .local)),
            activePaneID: UUID(),
            groupID: UUID(),
            groupName: "ghost-group",
            groupRemote: nil,
            indexInGroup: 0,
            closedAt: Date().addingTimeInterval(-(SessionStore.recentlyClosedTTL + 60))
        )
        let store = Self.makeStore()
        store.recentlyClosed = [stale]

        #expect(store.snapshot().recentlyClosed.isEmpty)
    }

    @Test("TTL is 24 hours — the privacy decision in ADR 0015")
    func ttlPinnedToPrivacyDecision() {
        #expect(SessionStore.recentlyClosedTTL == 24 * 60 * 60)
    }

    // MARK: - Reopen path

    @Test("reopen on empty buffer is a no-op returning nil")
    func reopenEmptyIsNoOp() {
        let store = Self.makeStore()
        let originalSelection = store.selectedSessionID
        store.recentlyClosed = []  // explicit empty
        #expect(store.reopenMostRecentlyClosed() == nil)
        #expect(store.selectedSessionID == originalSelection)
    }

    @Test("canReopenClosedWorkspace mirrors buffer non-emptiness")
    func canReopenReflectsBuffer() throws {
        let store = Self.makeStore(sessionCount: 1)
        #expect(store.canReopenClosedWorkspace == false)

        let id = try #require(store.selectedSessionID)
        store.closeSession(id: id)
        #expect(store.canReopenClosedWorkspace == true)

        _ = store.reopenMostRecentlyClosed()
        #expect(store.canReopenClosedWorkspace == false)
    }

    @Test("canReopenClosedWorkspace disables stale entries past the TTL")
    func canReopenHonorsTTL() throws {
        let store = Self.makeStore(sessionCount: 1)
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        let id = try #require(store.selectedSessionID)

        store.closeSession(id: id, now: t0)

        #expect(store.canReopenClosedWorkspace(now: t0))
        #expect(!store.recentlyClosed.isEmpty)
        #expect(
            !store.canReopenClosedWorkspace(
                now: t0.addingTimeInterval(SessionStore.recentlyClosedTTL + 1)
            ))
        #expect(!store.recentlyClosed.isEmpty)
    }

    @Test("restored empty tree can reopen persisted recently closed workspace")
    func restoredEmptyTreeCanReopenPersistedRecentlyClosedWorkspace() throws {
        let groupID = UUID()
        let pane = TerminalPane(title: "closed", workingDirectory: NSHomeDirectory(), executionPlan: .local)
        let entry = RecentlyClosedWorkspace(
            sessionID: UUID(),
            title: "closed",
            isTitleUserEdited: true,
            agentKind: .shell,
            layout: .pane(pane),
            activePaneID: pane.id,
            groupID: groupID,
            groupName: "restored",
            groupRemote: nil,
            indexInGroup: 0,
            closedAt: Date()
        )
        let store = SessionStore(
            restoring: SessionSnapshot(
                groups: [],
                selectedSessionID: nil,
                recentlyClosed: [entry]
            ))

        #expect(store.groups.isEmpty)
        #expect(store.canReopenClosedWorkspace)

        let reopenedID = try #require(store.reopenMostRecentlyClosed())

        #expect(store.selectedSessionID == reopenedID)
        #expect(store.recentlyClosed.isEmpty)
        #expect(store.groups.count == 1)
        #expect(store.groups[0].id == groupID)
        #expect(store.groups[0].name == "restored")
        #expect(store.groups[0].sessions.first?.id == reopenedID)
    }

    @Test("reopen pops the head, mints a new session id, and steals focus")
    func reopenMintsFreshIDAndStealsFocus() throws {
        let store = Self.makeStore(sessionCount: 2)
        let ids = store.groups[0].sessions.map(\.id)

        store.closeSession(id: ids[0])
        store.selectedSessionID = ids[1]

        let reopened = try #require(store.reopenMostRecentlyClosed())
        #expect(reopened != ids[0])  // fresh id, not the original
        #expect(store.selectedSessionID == reopened)  // focus stolen
        #expect(store.recentlyClosed.isEmpty)
        #expect(store.groups[0].sessions.contains(where: { $0.id == reopened }))
    }

    @Test("split layouts round-trip — splits and per-pane data survive reopen")
    func splitLayoutRoundTrip() throws {
        let leftPane = TerminalPane(title: "left", workingDirectory: NSHomeDirectory(), executionPlan: .local)
        let rightPane = TerminalPane(title: "right", workingDirectory: NSHomeDirectory(), executionPlan: .local)
        let split = TerminalSplit(
            orientation: .vertical,
            first: .pane(leftPane),
            second: .pane(rightPane),
            firstFraction: 0.4
        )
        let session = TerminalSession(
            title: "split-ws",
            workingDirectory: NSHomeDirectory(),
            agentKind: .shell,
            agentState: .idle,
            layout: .split(split),
            activePaneID: rightPane.id
        )
        let group = SessionGroup(name: "g", sessions: [session])
        let store = SessionStore(groups: [group])
        store.selectedSessionID = session.id
        store.closeSession(id: session.id)

        let reopenedID = try #require(store.reopenMostRecentlyClosed())
        let reopened = try #require(store.session(id: reopenedID))

        // Layout shape preserved.
        guard case let .split(restoredSplit) = reopened.layout else {
            Issue.record("Expected reopened layout to be .split")
            return
        }
        #expect(restoredSplit.orientation == .vertical)
        #expect(restoredSplit.firstFraction == 0.4)

        guard case let .pane(restoredLeft) = restoredSplit.first,
            case let .pane(restoredRight) = restoredSplit.second
        else {
            Issue.record("Expected both halves of restored split to be panes")
            return
        }
        // Pane titles preserved.
        #expect(restoredLeft.title == "left")
        #expect(restoredRight.title == "right")
        // Pane IDs are PRESERVED (no live collision) so each pane's daemon and
        // its agent runtime event file (keyed on pane.id) reattach (INT-578).
        // The split's own id has no external binding, so it's still reminted.
        #expect(restoredLeft.id == leftPane.id)
        #expect(restoredRight.id == rightPane.id)
        #expect(restoredSplit.id != split.id)
        // activePaneID still resolves to the (preserved) right pane.
        #expect(reopened.activePaneID == restoredRight.id)
    }

    @Test("captured cwd round-trips verbatim — spawn path handles validation")
    func capturedCwdRoundTripsVerbatim() throws {
        // The reopen path used to do a synchronous `FileManager.fileExists`
        // check per pane on the MainActor and fall back to `~` if the
        // directory was missing. That stalled the UI on slow / unmounted
        // volumes, so validation moved to libghostty's spawn path. Captured
        // cwds now pass through verbatim — even a path that no longer
        // exists is preserved into the reopened TerminalSession, and the
        // shell process handles the actual fallback.
        let bogusPath = "/nonexistent-int415-\(UUID().uuidString)"
        let entry = RecentlyClosedWorkspace(
            sessionID: UUID(),
            title: "vanished",
            isTitleUserEdited: true,  // gate-required signal
            agentKind: .shell,
            layout: .pane(TerminalPane(title: "vanished", workingDirectory: bogusPath, executionPlan: .local)),
            activePaneID: UUID(),
            groupID: UUID(),  // stale — the missing group is recreated
            groupName: "ghost",
            groupRemote: nil,
            indexInGroup: 0,
            closedAt: Date()
        )
        let store = Self.makeStore()
        store.recentlyClosed = [entry]

        let reopenedID = try #require(store.reopenMostRecentlyClosed())
        let reopened = try #require(store.session(id: reopenedID))

        guard case let .pane(restoredPane) = reopened.layout else {
            Issue.record("Expected single-pane layout")
            return
        }
        #expect(restoredPane.workingDirectory == bogusPath)
    }

    @Test("close on a bare unused shell does not occupy a persisted slot but is reopenable via the transient tier")
    func cacheQualityGateDropsBareShellFromPersistedButTransientHoldsIt() throws {
        // A new shell workspace with no user investment (default kind, no
        // rename, no notifications, single pane, default cwd) fails the
        // `isWorthRecording` gate and is dropped from the persisted
        // `recentlyClosed` buffer so it can't evict a more meaningful
        // older entry across relaunches. INT-426: the transient in-memory
        // tier still captures it so ⌘+⇧+T immediately after the close
        // resurrects it within the session. The gate only applies to
        // shell-exit AUTO-closes (`.processExit`) — a deliberate user close
        // of the same bare shell always persists (see the `.user` test below).
        let bareShell = TerminalSession(
            title: "shell",
            workingDirectory: NSHomeDirectory(),
            isTitleUserEdited: false,
            agentKind: .shell,
            agentState: .idle
        )
        let group = SessionGroup(name: "g", sessions: [bareShell])
        let store = SessionStore(groups: [group])
        store.selectedSessionID = bareShell.id

        store.closeSession(id: bareShell.id, origin: .processExit)
        #expect(store.recentlyClosed.isEmpty)
        #expect(store.lastClosedTransient != nil)
        #expect(store.canReopenClosedWorkspace == true)
    }

    @Test("a deliberate user close persists a bare shell even though the quality gate would drop it")
    func userOriginCloseAlwaysPersistsEvenABareShell() throws {
        // Product decision: the isWorthRecording gate exists to keep noisy
        // shell-exit AUTO-closes out of the durable list, not to filter
        // closes the user explicitly asked for. `origin` defaults to `.user`,
        // so every existing explicit close call site (⌘W, ⇧⌘W, palette,
        // group close) keeps this behavior without passing anything.
        let bareShell = TerminalSession(
            title: "shell",
            workingDirectory: NSHomeDirectory(),
            isTitleUserEdited: false,
            agentKind: .shell,
            agentState: .idle
        )
        let group = SessionGroup(name: "g", sessions: [bareShell])
        let store = SessionStore(groups: [group])
        store.selectedSessionID = bareShell.id

        store.closeSession(id: bareShell.id, origin: .user)

        #expect(store.recentlyClosed.count == 1)
        #expect(store.recentlyClosed.first?.sessionID == bareShell.id)
    }

    @Test("a process-exit auto-close still drops a bare shell — the quality gate applies")
    func processExitOriginCloseStillGatesABareShell() throws {
        let bareShell = TerminalSession(
            title: "shell",
            workingDirectory: NSHomeDirectory(),
            isTitleUserEdited: false,
            agentKind: .shell,
            agentState: .idle
        )
        let group = SessionGroup(name: "g", sessions: [bareShell])
        let store = SessionStore(groups: [group])
        store.selectedSessionID = bareShell.id

        store.closeSession(id: bareShell.id, origin: .processExit)

        #expect(store.recentlyClosed.isEmpty)
        // Still reopenable via the transient one-slot tier — unchanged.
        #expect(store.lastClosedTransient?.sessionID == bareShell.id)
    }

    @Test("a process-exit auto-close persists a bare shell with an open document")
    func processExitOriginClosePersistsBareShellWithOpenDocument() throws {
        let bareShell = TerminalSession(
            title: "shell",
            workingDirectory: NSHomeDirectory(),
            isTitleUserEdited: false,
            agentKind: .shell,
            agentState: .idle
        )
        let session = try #require(
            PaneLayoutReducer.openDocumentTab(
                fileURL: URL(fileURLWithPath: "/tmp/notes.md"),
                associatedTerminalPaneID: bareShell.activePaneID,
                in: bareShell,
                now: Date()
            )?.session
        )
        let store = SessionStore(groups: [SessionGroup(name: "g", sessions: [session])])

        store.closeSession(id: session.id, origin: .processExit)

        #expect(store.recentlyClosed.first?.sessionID == session.id)
    }

    @Test("a process-exit auto-close of a meaningful workspace still persists — gate passes as today")
    func processExitOriginClosePersistsAMeaningfulWorkspace() throws {
        let claudeSession = TerminalSession(
            title: "Claude",
            workingDirectory: NSHomeDirectory(),
            agentKind: .claudeCode,
            agentState: .idle
        )
        let group = SessionGroup(name: "g", sessions: [claudeSession])
        let store = SessionStore(groups: [group])
        store.selectedSessionID = claudeSession.id

        store.closeSession(id: claudeSession.id, origin: .processExit)

        #expect(store.recentlyClosed.count == 1)
        #expect(store.recentlyClosed.first?.sessionID == claudeSession.id)
    }

    @Test("INT-426 — reopen via transient tier resurrects a gate-failing bare shell")
    func transientTierReopensBareShell() throws {
        let bareShell = TerminalSession(
            title: "shell",
            workingDirectory: NSHomeDirectory(),
            isTitleUserEdited: false,
            agentKind: .shell,
            agentState: .idle
        )
        let group = SessionGroup(name: "g", sessions: [bareShell])
        let store = SessionStore(groups: [group])
        store.selectedSessionID = bareShell.id

        store.closeSession(id: bareShell.id, origin: .processExit)
        #expect(store.recentlyClosed.isEmpty)  // gate rejected persistence
        #expect(store.lastClosedTransient != nil)

        let reopened = try #require(store.reopenMostRecentlyClosed())
        #expect(reopened != bareShell.id)  // fresh id
        #expect(store.selectedSessionID == reopened)  // focus stolen
        #expect(store.lastClosedTransient == nil)  // transient consumed
    }

    @Test("INT-426 — transient slot overwrites on each close; reopen drains it once")
    func transientTierSingleSlotSemantics() throws {
        let bareShell1 = TerminalSession(
            title: "shell-1", workingDirectory: NSHomeDirectory(),
            isTitleUserEdited: false, agentKind: .shell, agentState: .idle
        )
        let bareShell2 = TerminalSession(
            title: "shell-2", workingDirectory: NSHomeDirectory(),
            isTitleUserEdited: false, agentKind: .shell, agentState: .idle
        )
        let group = SessionGroup(name: "g", sessions: [bareShell1, bareShell2])
        let store = SessionStore(groups: [group])
        store.selectedSessionID = bareShell1.id

        store.closeSession(id: bareShell1.id, now: Date(timeIntervalSince1970: 1000), origin: .processExit)
        store.closeSession(id: bareShell2.id, now: Date(timeIntervalSince1970: 2000), origin: .processExit)
        // Transient is a single slot — only the most-recent close survives.
        #expect(store.lastClosedTransient?.sessionID == bareShell2.id)
        #expect(store.recentlyClosed.isEmpty)

        _ = store.reopenMostRecentlyClosed()
        #expect(store.lastClosedTransient == nil)
        // Second reopen finds nothing — bareShell1 was overwritten, not stacked.
        #expect(store.reopenMostRecentlyClosed() == nil)
    }

    @Test("INT-426 — transient and persisted hit on the same close; reopen drains both, no duplicate")
    func transientAndPersistedNoDoubleReopen() throws {
        // A workspace that passes the gate lands in BOTH tiers with the
        // same sessionID. Reopen must consume both, otherwise the next
        // ⌘+⇧+T would pop the same workspace twice.
        let session = TerminalSession(
            title: "agent",
            workingDirectory: NSHomeDirectory(),
            isTitleUserEdited: false,
            agentKind: .claudeCode,  // gate-admitting
            agentState: .idle
        )
        let group = SessionGroup(name: "g", sessions: [session])
        let store = SessionStore(groups: [group])
        store.selectedSessionID = session.id

        store.closeSession(id: session.id)
        #expect(store.recentlyClosed.count == 1)
        #expect(store.lastClosedTransient?.sessionID == session.id)

        _ = store.reopenMostRecentlyClosed()
        #expect(store.lastClosedTransient == nil)
        #expect(store.recentlyClosed.isEmpty)  // not left behind as a phantom
    }

    @Test("INT-426 — interleaved bare + agent: each reopen pulls the right tier")
    func transientLayeredOverPersisted() throws {
        // Close agent first (lands in both), then bare shell (transient
        // only). First reopen pulls the bare shell from transient.
        // Second reopen falls back to the agent in persisted.
        let agent = TerminalSession(
            title: "agent", workingDirectory: NSHomeDirectory(),
            isTitleUserEdited: false, agentKind: .claudeCode, agentState: .idle
        )
        let bareShell = TerminalSession(
            title: "shell", workingDirectory: NSHomeDirectory(),
            isTitleUserEdited: false, agentKind: .shell, agentState: .idle
        )
        let group = SessionGroup(name: "g", sessions: [agent, bareShell])
        let store = SessionStore(groups: [group])
        store.selectedSessionID = agent.id

        let t1 = Date()
        let t2 = t1.addingTimeInterval(1)
        let t3 = t1.addingTimeInterval(2)
        store.closeSession(id: agent.id, now: t1)
        store.closeSession(id: bareShell.id, now: t2)

        // First reopen: bare shell (newer, transient).
        let firstReopen = try #require(store.reopenMostRecentlyClosed(now: t3))
        let firstSession = try #require(
            store.groups[0].sessions.first(where: { $0.id == firstReopen })
        )
        #expect(firstSession.agentKind == .shell)

        // Second reopen: agent (from persisted).
        let secondReopen = try #require(store.reopenMostRecentlyClosed(now: t3))
        let secondSession = try #require(
            store.groups[0].sessions.first(where: { $0.id == secondReopen })
        )
        #expect(secondSession.agentKind == .claudeCode)

        #expect(store.recentlyClosed.isEmpty)
        #expect(store.lastClosedTransient == nil)
    }

    @Test("INT-426 — transient is TTL-pruned alongside the persisted tier")
    func transientTTLPruned() throws {
        let bareShell = TerminalSession(
            title: "shell", workingDirectory: NSHomeDirectory(),
            isTitleUserEdited: false, agentKind: .shell, agentState: .idle
        )
        let group = SessionGroup(name: "g", sessions: [bareShell])
        let store = SessionStore(groups: [group])
        store.selectedSessionID = bareShell.id

        // Close at t0. Transient captures.
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        store.closeSession(id: bareShell.id, now: t0)
        #expect(store.lastClosedTransient != nil)

        // Long-running session: query reopen with `now` past the TTL.
        // Transient should be pruned, not resurrected as an ancient
        // close.
        let future = t0.addingTimeInterval(SessionStore.recentlyClosedTTL + 60)
        #expect(store.reopenMostRecentlyClosed(now: future) == nil)
        #expect(store.lastClosedTransient == nil)
        #expect(store.canReopenClosedWorkspace == false)
    }

    @Test("INT-426 — depth-cap bail preserves BOTH tiers when the entry is shared")
    func depthCapBailDrainsBothTiers() throws {
        // A gate-admitting workspace lands in both tiers. The captured
        // entry's layout is then forced past the depth cap (simulating
        // a tampered cache row that survived JSON-shape validation).
        // The bail must clear BOTH the transient slot and the persisted
        // twin — otherwise the next ⌘+⇧+T hits the same guard and the
        // user perceives the feature as broken for two consecutive
        // keypresses.
        let session = TerminalSession(
            title: "claude", workingDirectory: NSHomeDirectory(),
            isTitleUserEdited: false, agentKind: .claudeCode, agentState: .idle
        )
        let group = SessionGroup(name: "g", sessions: [session])
        let store = SessionStore(groups: [group])
        store.selectedSessionID = session.id
        store.closeSession(id: session.id)
        #expect(store.recentlyClosed.count == 1)
        #expect(store.lastClosedTransient != nil)

        // Replace both tiers with a pathological-layout twin sharing
        // the same sessionID. The internal(set) on both properties is
        // there exactly so tests can stage adversarial state without
        // forging closes.
        var pathologicalLayout: TerminalPaneLayout = .pane(
            TerminalPane(title: "deep", workingDirectory: NSHomeDirectory(), executionPlan: .local)
        )
        for _ in 0..<100 {
            pathologicalLayout = .split(
                TerminalSplit(
                    orientation: .vertical,
                    first: pathologicalLayout,
                    second: .pane(
                        TerminalPane(
                            title: "stub",
                            workingDirectory: NSHomeDirectory(),
                            executionPlan: .local
                        ))
                ))
        }
        let twin = RecentlyClosedWorkspace(
            sessionID: store.lastClosedTransient!.sessionID,
            title: "claude",
            isTitleUserEdited: false,
            agentKind: .claudeCode,
            layout: pathologicalLayout,
            activePaneID: UUID(),
            groupID: group.id,
            groupName: "g",
            groupRemote: nil,
            indexInGroup: 0,
            closedAt: Date()
        )
        store.lastClosedTransient = twin
        store.recentlyClosed = [twin]

        // Depth-guard bails: recovery rows stay so a failed reopen cannot
        // erase the only visible recovery entry.
        #expect(store.reopenMostRecentlyClosed() == nil)
        #expect(store.lastClosedTransient == twin)
        #expect(store.recentlyClosed == [twin])
        #expect(store.reopenMostRecentlyClosed() == nil)
        #expect(store.recentlyClosed == [twin])
    }

    @Test("INT-426 — transient does NOT persist across SessionSnapshot encode/decode")
    func transientNotPersisted() throws {
        let bareShell = TerminalSession(
            title: "shell", workingDirectory: NSHomeDirectory(),
            isTitleUserEdited: false, agentKind: .shell, agentState: .idle
        )
        let group = SessionGroup(name: "g", sessions: [bareShell])
        let store = SessionStore(groups: [group])
        store.selectedSessionID = bareShell.id
        store.closeSession(id: bareShell.id, origin: .processExit)
        #expect(store.lastClosedTransient != nil)

        // Round-trip through the snapshot: transient must not leak into
        // SessionSnapshot.recentlyClosed (the on-disk JSON).
        let snapshot = store.snapshot()
        #expect(snapshot.recentlyClosed.isEmpty)

        let restored = SessionStore(restoring: snapshot)
        #expect(restored.lastClosedTransient == nil)
        #expect(restored.canReopenClosedWorkspace == false)
    }

    @Test("close on a shell with a non-default cwd is recorded — cwd is meaningful spawn metadata")
    func cacheQualityGateAdmitsNonDefaultCwd() throws {
        // A bare shell with no rename / no notifications / single pane,
        // BUT cd'd into a project directory, IS worth recording — the
        // captured cwd is exactly the spawn metadata this feature exists
        // to preserve. Otherwise `cd ~/Projects/x && exit && ⌘+⇧+T` would
        // silently drop on the floor.
        let projectShell = TerminalSession(
            title: "shell",  // default-feeling title
            workingDirectory: "/tmp/awesomux-int-415-project",  // not ~, not $HOME
            isTitleUserEdited: false,
            agentKind: .shell,
            agentState: .idle
        )
        let group = SessionGroup(name: "g", sessions: [projectShell])
        let store = SessionStore(groups: [group])
        store.selectedSessionID = projectShell.id

        store.closeSession(id: projectShell.id)
        #expect(store.recentlyClosed.count == 1)
        #expect(store.recentlyClosed.first?.layout.firstPane?.workingDirectory == "/tmp/awesomux-int-415-project")
    }

    @Test("close on an agent-kind workspace is always recorded regardless of activity")
    func cacheQualityGateAdmitsAgentKind() throws {
        let claudeSession = TerminalSession(
            title: "claude",  // default-feeling title
            workingDirectory: NSHomeDirectory(),
            isTitleUserEdited: false,
            agentKind: .claudeCode,  // gate-admitting signal
            agentState: .idle
        )
        let group = SessionGroup(name: "g", sessions: [claudeSession])
        let store = SessionStore(groups: [group])
        store.selectedSessionID = claudeSession.id

        store.closeSession(id: claudeSession.id)
        #expect(store.recentlyClosed.count == 1)
    }

    @Test("reopen into a deleted group recreates that group in a non-empty tree")
    func reopenIntoDeletedGroup() throws {
        let store = Self.makeStore(sessionCount: 1)
        let ghostGroupID = UUID()
        let entry = RecentlyClosedWorkspace(
            sessionID: UUID(),
            title: "orphan",
            isTitleUserEdited: false,
            agentKind: .shell,
            layout: .pane(TerminalPane(title: "orphan", workingDirectory: NSHomeDirectory(), executionPlan: .local)),
            activePaneID: UUID(),
            groupID: ghostGroupID,  // never existed in this store
            groupName: "ghost",
            groupRemote: nil,
            indexInGroup: 999,  // way past the end
            closedAt: Date()
        )
        store.recentlyClosed = [entry]

        let reopenedID = try #require(store.reopenMostRecentlyClosed())
        // The missing group is recreated at the end rather than the workspace
        // being dumped into whichever group happens to be first (INT-166).
        let recreated = try #require(store.groups.last)
        #expect(recreated.id == ghostGroupID)
        #expect(recreated.name == "ghost")
        #expect(recreated.sessions.last?.id == reopenedID)
        // The original live group is left untouched.
        #expect(store.groups[0].sessions.allSatisfy { $0.id != reopenedID })
    }

    @Test("reopen with no groups creates a destination group")
    func reopenWithEmptyGroups() throws {
        let groupID = UUID()
        var groups: [SessionGroup] = []
        var recentlyClosed = [
            RecentlyClosedWorkspace(
                sessionID: UUID(),
                title: "orphan",
                isTitleUserEdited: false,
                agentKind: .shell,
                layout: .pane(TerminalPane(title: "orphan", workingDirectory: NSHomeDirectory(), executionPlan: .local)),
                activePaneID: UUID(),
                groupID: groupID,
                groupName: "ghost",
                groupRemote: nil,
                indexInGroup: 0,
                closedAt: Date()
            )
        ]
        var lastClosedTransient: RecentlyClosedWorkspace?

        let reopenedID = RecentlyClosedWorkspaceReducer.reopenMostRecentlyClosed(
            in: &groups,
            recentlyClosed: &recentlyClosed,
            lastClosedTransient: &lastClosedTransient,
            now: Date()
        )

        #expect(reopenedID != nil)
        #expect(recentlyClosed.isEmpty)
        #expect(groups.count == 1)
        #expect(groups[0].id == groupID)
        #expect(groups[0].name == "ghost")
        #expect(groups[0].sessions.first?.id == reopenedID)
    }

    // MARK: - Schema compatibility

    @Test("pre-INT-415 snapshot (no recentlyClosed key) decodes with empty buffer")
    func decodesPreFeatureSnapshot() throws {
        let json = """
            {
              "schemaVersion": 1,
              "groups": [
                {
                  "id": "11111111-1111-1111-1111-111111111111",
                  "name": "g",
                  "sessions": []
                }
              ]
            }
            """.data(using: .utf8)!

        let snapshot = try SessionSnapshot.decode(from: json)
        #expect(snapshot.recentlyClosed.isEmpty)
        #expect(snapshot.groups.count == 1)
    }

    @Test("malformed recentlyClosed entry is skipped, rest of snapshot survives")
    func malformedEntryIsIsolated() throws {
        let valid = RecentlyClosedWorkspace(
            sessionID: UUID(),
            title: "ok",
            isTitleUserEdited: false,
            agentKind: .shell,
            layout: .pane(TerminalPane(title: "ok", workingDirectory: NSHomeDirectory(), executionPlan: .local)),
            activePaneID: UUID(),
            groupID: UUID(),
            groupName: "g",
            groupRemote: nil,
            indexInGroup: 0,
            closedAt: Date()
        )
        let validData = try JSONEncoder().encode([valid])
        let validJSONFragment = String(data: validData, encoding: .utf8)!
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))

        // Build a snapshot with one valid entry and one structurally-broken
        // entry (a string where an object is expected). The tolerant decoder
        // should keep the valid entry.
        let json = """
            {
              "schemaVersion": 1,
              "groups": [
                {
                  "id": "22222222-2222-2222-2222-222222222222",
                  "name": "g",
                  "sessions": []
                }
              ],
              "recentlyClosed": ["this should be an object, not a string", \(validJSONFragment)]
            }
            """.data(using: .utf8)!

        let snapshot = try SessionSnapshot.decode(from: json)
        #expect(snapshot.recentlyClosed.count == 1)
        #expect(snapshot.recentlyClosed.first?.title == "ok")
    }

    @Test("empty recentlyClosed omits the JSON key entirely")
    func emptyBufferOmitsKey() throws {
        let snapshot = SessionSnapshot(
            groups: [SessionGroup(name: "g", sessions: [])],
            selectedSessionID: nil,
            recentlyClosed: []
        )
        let data = try JSONEncoder().encode(snapshot)
        let asString = String(data: data, encoding: .utf8) ?? ""
        #expect(!asString.contains("recentlyClosed"))
    }

    // MARK: - Behavioral guarantees the implementation depends on

    @Test("reopen clamps active agent state to .idle")
    func reopenResetsAgentState() throws {
        // A session that was running an agent at close time reopens `.idle`:
        // active states mean nothing without the run that produced them
        // (same policy as launch restore's `restoredAgentExecutionState`).
        let session = TerminalSession(
            title: "claude-work",
            workingDirectory: NSHomeDirectory(),
            agentKind: .claudeCode,
            agentState: .running
        )
        let group = SessionGroup(name: "g", sessions: [session])
        let store = SessionStore(groups: [group])
        store.selectedSessionID = session.id
        store.closeSession(id: session.id)

        let reopenedID = try #require(store.reopenMostRecentlyClosed())
        let reopened = try #require(store.session(id: reopenedID))
        #expect(reopened.agentState == .idle)
        #expect(reopened.agentKind == .claudeCode)  // kind preserved
    }

    @Test("reopen preserves .waiting when the daemon identity is kept")
    func reopenPreservesWaitingWithDaemonIdentity() throws {
        // Close-then-reopen keeps pane id + terminal session id (INT-578), so
        // a still-blocked waiting agent must reopen badged — aligned with
        // launch restore's `.waiting` round-trip policy.
        let session = TerminalSession(
            title: "claude-work",
            workingDirectory: NSHomeDirectory(),
            agentKind: .claudeCode,
            agentState: .waiting
        )
        // A sibling session keeps the store non-empty so the close is a real
        // removal, not a last-workspace in-place recycle (which keeps the pane
        // id live and correctly forces the reopen to start fresh).
        let sibling = TerminalSession(title: "other", workingDirectory: "~")
        let store = SessionStore(
            groups: [SessionGroup(name: "g", sessions: [session, sibling])]
        )
        store.selectedSessionID = session.id
        store.closeSession(id: session.id)

        let reopenedID = try #require(store.reopenMostRecentlyClosed())
        let reopened = try #require(store.session(id: reopenedID))
        #expect(reopened.agentState == .waiting)
    }

    @Test("closing an unknown session id is a silent no-op")
    func closeUnknownIDIsNoOp() {
        let store = Self.makeStore(sessionCount: 1)
        store.closeSession(id: UUID())
        #expect(store.recentlyClosed.isEmpty)
        #expect(store.groups[0].sessions.count == 1)
    }

    @Test("minimal close-then-reopen loop: only workspace in only group")
    func minimalCloseReopenLoop() throws {
        let store = Self.makeStore(sessionCount: 1)
        let originalID = try #require(store.selectedSessionID)

        store.closeSession(id: originalID)
        #expect(store.selectedSessionID == nil)
        #expect(store.groups[0].sessions.isEmpty)
        #expect(store.recentlyClosed.count == 1)

        let reopenedID = try #require(store.reopenMostRecentlyClosed())
        #expect(reopenedID != originalID)
        #expect(store.selectedSessionID == reopenedID)
        #expect(store.groups[0].sessions.count == 1)
        #expect(store.recentlyClosed.isEmpty)
    }

    @Test("deleted-group fallback recreates the group and leaves live sessions unmoved")
    func deletedGroupFallbackRecreatesGroup() throws {
        // Pre-populate the only group with 3 sessions to prove the orphaned
        // workspace does not shove them — it now lands in a recreated group.
        let store = Self.makeStore(sessionCount: 3)
        let preReopenIDs = store.groups[0].sessions.map(\.id)

        let entry = RecentlyClosedWorkspace(
            sessionID: UUID(),
            title: "orphaned",
            isTitleUserEdited: false,
            agentKind: .shell,
            layout: .pane(TerminalPane(title: "orphaned", workingDirectory: NSHomeDirectory(), executionPlan: .local)),
            activePaneID: UUID(),
            groupID: UUID(),  // dead — group doesn't exist
            groupName: "ghost",
            groupRemote: nil,
            indexInGroup: 0,
            closedAt: Date()
        )
        store.recentlyClosed = [entry]

        let reopenedID = try #require(store.reopenMostRecentlyClosed())
        // Original group is untouched; the restored workspace lands in a fresh
        // group appended at the end (INT-166).
        #expect(store.groups[0].sessions.map(\.id) == preReopenIDs)
        #expect(store.groups.last?.sessions.last?.id == reopenedID)
    }

    @Test("captured layout exceeding the depth cap is dropped, not recursed")
    func adversarialDeepLayoutIsDropped() throws {
        // SessionStore.maxRestoredLayoutDepth is fileprivate; bake the cap
        // (64) into the test by going well past it. If the cap ever drops
        // below 100, raise this; if it rises above 100, raise this.
        let deeperThanCap = 100
        var layout: TerminalPaneLayout = .pane(
            TerminalPane(title: "leaf", workingDirectory: NSHomeDirectory(), executionPlan: .local)
        )
        for _ in 0..<deeperThanCap {
            layout = .split(
                TerminalSplit(
                    orientation: .vertical,
                    first: layout,
                    second: .pane(
                        TerminalPane(
                            title: "stub",
                            workingDirectory: NSHomeDirectory(),
                            executionPlan: .local
                        ))
                ))
        }
        let entry = RecentlyClosedWorkspace(
            sessionID: UUID(),
            title: "deep",
            isTitleUserEdited: false,
            agentKind: .shell,
            layout: layout,
            activePaneID: UUID(),
            groupID: UUID(),
            groupName: "g",
            groupRemote: nil,
            indexInGroup: 0,
            closedAt: Date()
        )
        let store = Self.makeStore(sessionCount: 1)
        let preGroupCount = store.groups[0].sessions.count
        store.recentlyClosed = [entry]

        // Entry stays available without inserting a session.
        #expect(store.reopenMostRecentlyClosed() == nil)
        #expect(store.recentlyClosed == [entry])
        #expect(store.groups[0].sessions.count == preGroupCount)
    }

    @Test("reopen runs captured title through the sanitiser (drops RTL override)")
    func reopenSanitisesTitle() throws {
        let entry = RecentlyClosedWorkspace(
            sessionID: UUID(),
            // U+202E RIGHT-TO-LEFT OVERRIDE in the middle of a title
            title: "safe\u{202E}danger",
            isTitleUserEdited: true,
            agentKind: .shell,
            layout: .pane(TerminalPane(title: "leaf", workingDirectory: NSHomeDirectory(), executionPlan: .local)),
            activePaneID: UUID(),
            groupID: UUID(),
            groupName: "g",
            groupRemote: nil,
            indexInGroup: 0,
            closedAt: Date()
        )
        let store = Self.makeStore()
        store.recentlyClosed = [entry]

        let reopenedID = try #require(store.reopenMostRecentlyClosed())
        let reopened = try #require(store.session(id: reopenedID))
        #expect(!reopened.title.contains("\u{202E}"))
    }

    @Test("non-empty recentlyClosed round-trips through Codable")
    func recentlyClosedRoundTrip() throws {
        let entry = RecentlyClosedWorkspace(
            sessionID: UUID(),
            title: "round",
            isTitleUserEdited: true,
            agentKind: .claudeCode,
            layout: .pane(TerminalPane(title: "round", workingDirectory: NSHomeDirectory(), executionPlan: .local)),
            activePaneID: UUID(),
            groupID: UUID(),
            groupName: "g",
            groupRemote: nil,
            indexInGroup: 3,
            closedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let original = SessionSnapshot(
            groups: [SessionGroup(name: "g", sessions: [])],
            selectedSessionID: nil,
            recentlyClosed: [entry]
        )
        let encoder = JSONEncoder()
        let decoded = try SessionSnapshot.decode(from: encoder.encode(original))

        #expect(decoded.recentlyClosed.count == 1)
        let round = try #require(decoded.recentlyClosed.first)
        #expect(round.title == "round")
        #expect(round.agentKind == .claudeCode)
        #expect(round.indexInGroup == 3)
        #expect(round.closedAt == entry.closedAt)
    }

    // MARK: - Reopen inherits live group color (INT-211 follow-up)

    @Test("reopening a closed workspace into a colored group inherits the live group's color")
    func reopenInheritsGroupColor() throws {
        // Build a store whose single group has a user-chosen color, close
        // a workspace, then reopen. The workspace should land back in the
        // same group which still carries the tint — RecentlyClosedWorkspace
        // links by groupID, not by snapshotted color, so the color is
        // implicitly preserved.
        let store = Self.makeStore(sessionCount: 1, groupName: "design")
        let groupID = store.groups[0].id
        let session = try #require(store.selectedSession)

        #expect(store.setGroupColor(id: groupID, color: .sky))
        #expect(store.groups[0].color == .sky)

        store.closeSession(id: session.id)
        #expect(store.recentlyClosed.count == 1)
        #expect(store.groups[0].sessions.isEmpty)
        #expect(store.groups[0].color == .sky, "color survives the close itself")

        let reopenedID = try #require(store.reopenMostRecentlyClosed())
        let reopened = try #require(
            store.groups.first(where: { $0.sessions.contains(where: { $0.id == reopenedID }) })
        )
        #expect(
            reopened.color == .sky,
            "reopened workspace lands in the original group and inherits its current color")
    }

    @Test("recolor while a workspace is closed: reopen picks up the NEW color")
    func reopenPicksUpLiveColor() throws {
        // Close a workspace from a teal group, then recolor the group to
        // pink before reopen. The reopen path queries the live group, so
        // the workspace returns to a pink group — color is not snapshotted
        // at close time, which is the intended behavior.
        let store = Self.makeStore(sessionCount: 1, groupName: "design")
        let groupID = store.groups[0].id
        let session = try #require(store.selectedSession)
        #expect(store.setGroupColor(id: groupID, color: .teal))

        store.closeSession(id: session.id)
        #expect(store.setGroupColor(id: groupID, color: .pink))

        let reopenedID = try #require(store.reopenMostRecentlyClosed())
        let reopened = try #require(
            store.groups.first(where: { $0.sessions.contains(where: { $0.id == reopenedID }) })
        )
        #expect(reopened.color == .pink)
    }
}
