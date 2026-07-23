import AwesoMuxBridgeProtocol
import Foundation
import Observation
import Testing
@testable import AwesoMuxCore

/// F30 PR1: commit path pilots + oracle that derived caches match a full rebuild.
@MainActor
@Suite("SessionStore — Workspace Mutation Commit (F30)")
struct WorkspaceMutationCommitTests {

    // MARK: - Oracle

    /// Brute-force recompute of derived caches from `_groups`. A path that
    /// forgot commit fails here even when in-path DEBUG asserts never ran.
    private func assertDerivedCachesMatchOracle(
        _ store: SessionStore,
        now: Date = Date(),
        _ sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let expected = SessionStoreIndex.build(from: store.groups)

        #expect(
            store.index.positionsBySessionID == expected.positionsBySessionID,
            "positions drift",
            sourceLocation: sourceLocation
        )
        #expect(
            store.unreadNotificationTotal == expected.unreadNotificationTotal,
            "unread total drift",
            sourceLocation: sourceLocation
        )
        #expect(
            store.index.livePaneIDs == expected.livePaneIDs,
            "livePaneIDs drift",
            sourceLocation: sourceLocation
        )
        #expect(
            store.index.remotePaneIDs == expected.remotePaneIDs,
            "remotePaneIDs drift",
            sourceLocation: sourceLocation
        )
        #expect(
            store.index.durableAtRiskSessionIDs == expected.durableAtRiskSessionIDs,
            "durableAtRiskSessionIDs drift",
            sourceLocation: sourceLocation
        )
        #expect(
            store.index.freshnessCandidateSessionIDs == expected.freshnessCandidateSessionIDs,
            "freshnessCandidateSessionIDs drift",
            sourceLocation: sourceLocation
        )

        let bruteForceRiskIDs = Set(
            store.groups.flatMap(\.sessions).filter { $0.isQuitRisk(at: now) }.map(\.id)
        )
        let cachedRiskIDs = Set(store.sessionsAtRiskOnQuit(at: now).map(\.id))
        #expect(
            cachedRiskIDs == bruteForceRiskIDs,
            "quit-risk cache drift",
            sourceLocation: sourceLocation
        )
    }

    // MARK: - closeSession (structural pilot)

    @Test("closeSession rebuilds index, moves selection, and prunes pins")
    func closeSessionRebuildsSelectionAndPrunesPins() {
        let first = makeSession("first")
        let second = makeSession("second")
        let third = makeSession("third")
        let store = SessionStore(
            groups: [
                SessionGroup(name: "main", sessions: [first, second]),
                SessionGroup(name: "scratch", sessions: [third]),
            ],
            selectedSessionID: second.id,
            pinnedSessionIDs: [second.id, third.id]
        )

        store.closeSession(id: second.id)

        #expect(store.session(id: second.id) == nil)
        // Replacement prefers next-in-order (next group) before previous sibling.
        #expect(store.selectedSessionID == third.id)
        #expect(!store.pinnedSessionIDs.contains(second.id))
        #expect(store.pinnedSessionIDs == [third.id])
        #expect(store.index.positionsBySessionID[second.id] == nil)
        #expect(store.index.positionsBySessionID[first.id] != nil)
        assertDerivedCachesMatchOracle(store)
    }

    @Test("closeSession of non-selected keeps selection and still rebuilds")
    func closeNonSelectedSessionKeepsSelection() {
        let first = makeSession("first")
        let second = makeSession("second")
        let store = SessionStore(
            groups: [SessionGroup(name: "main", sessions: [first, second])],
            selectedSessionID: first.id
        )

        store.closeSession(id: second.id)

        #expect(store.selectedSessionID == first.id)
        #expect(store.session(id: second.id) == nil)
        assertDerivedCachesMatchOracle(store)
    }

    // MARK: - applyPaneUpdate (attention pilot)

    @Test("attention update patches unread and reclassifies risk via commit")
    func attentionUpdatePatchesUnreadAndRisk() {
        let session = makeSession("agent", agentKind: .shell)
        let store = SessionStore(groups: [SessionGroup(name: "main", sessions: [session])])
        #expect(store.unreadNotificationTotal == 0)
        #expect(store.sessionsAtRiskOnQuit.isEmpty)

        // applyDetectedAgentState → applyPaneUpdate → commit(unread + risk)
        store.applyDetectedAgentState(
            id: session.id,
            detectedState: .thinking,
            agentKind: .codex,
            clearsAttention: false,
            unreadNotificationDelta: 2
        )

        #expect(store.unreadNotificationTotal == 2)
        #expect(store.sessionsAtRiskOnQuit.map(\.id) == [session.id])
        assertDerivedCachesMatchOracle(store)
    }

    @Test("markSessionNeedsAttention patches unread total via commit")
    func markNeedsAttentionPatchesUnread() {
        let session = makeSession("shell")
        let store = SessionStore(groups: [SessionGroup(name: "main", sessions: [session])])

        store.markSessionNeedsAttention(id: session.id, unreadNotificationDelta: 1)
        #expect(store.unreadNotificationTotal == 1)

        store.markSessionNeedsAttention(id: session.id, unreadNotificationDelta: 3)
        #expect(store.unreadNotificationTotal == 4)
        assertDerivedCachesMatchOracle(store)
    }

    @Test("permission prompt attention patches unread via commit")
    func permissionPromptAttentionPatchesUnread() {
        let session = makeSession("remote")
        let paneID = session.activePaneID
        let store = SessionStore(groups: [SessionGroup(name: "main", sessions: [session])])

        store.updatePermissionPromptAttention(
            sessionID: session.id,
            paneID: paneID,
            countDelta: 2,
            hasPending: true
        )

        #expect(store.unreadNotificationTotal == 2)
        #expect(store.session(id: session.id)?.unreadNotificationCount == 2)
        assertDerivedCachesMatchOracle(store)
    }

    // MARK: - Structural rebuild migration (PR2)

    @Test("addSession rebuilds index and selects the new session")
    func addSessionRebuildsAndSelects() {
        let existing = makeSession("existing")
        let store = SessionStore(
            groups: [SessionGroup(name: "main", sessions: [existing])],
            selectedSessionID: existing.id
        )

        let newID = store.addSession(title: "fresh", groupName: "main")

        #expect(store.selectedSessionID == newID)
        #expect(store.session(id: newID)?.title == "fresh")
        #expect(store.index.positionsBySessionID[newID] != nil)
        assertDerivedCachesMatchOracle(store)
    }

    @Test("moveSession rebuilds positions without changing selection")
    func moveSessionRebuildsPositions() {
        let first = makeSession("first")
        let second = makeSession("second")
        let third = makeSession("third")
        let main = SessionGroup(name: "main", sessions: [first, second])
        let scratch = SessionGroup(name: "scratch", sessions: [third])
        let store = SessionStore(
            groups: [main, scratch],
            selectedSessionID: second.id
        )

        store.moveSession(id: second.id, toGroupID: scratch.id, atIndex: SessionStore.appendIndex)

        #expect(store.selectedSessionID == second.id)
        #expect(store.groups[1].sessions.map(\.id) == [third.id, second.id])
        assertDerivedCachesMatchOracle(store)
    }

    @Test("splitActivePane rebuilds live pane set")
    func splitActivePaneRebuildsLivePanes() {
        let session = makeSession("solo")
        let store = SessionStore(groups: [SessionGroup(name: "main", sessions: [session])])
        let before = store.index.livePaneIDs.count

        let newPaneID = store.splitActivePane(orientation: .vertical, in: session.id)
        #expect(newPaneID != nil)
        #expect(store.index.livePaneIDs.count == before + 1)
        assertDerivedCachesMatchOracle(store)
    }

    @Test("removeGroup prunes pins via full rebuild")
    func removeGroupPrunesPinsViaCommit() {
        let a = makeSession("a")
        let b = makeSession("b")
        let groupA = SessionGroup(name: "A", sessions: [a])
        let groupB = SessionGroup(name: "B", sessions: [b])
        let store = SessionStore(
            groups: [groupA, groupB],
            selectedSessionID: a.id,
            pinnedSessionIDs: [a.id, b.id]
        )

        // Empty group A first by moving a out, then remove — removeGroup refuses non-empty.
        // Simpler: close a then remove empty group if allowed; use two groups and remove B after close b.
        store.closeSession(id: b.id)
        #expect(store.pinnedSessionIDs == [a.id])
        // B is empty after close; remove it.
        let removed = store.removeGroup(id: groupB.id)
        #expect(removed)
        assertDerivedCachesMatchOracle(store)
    }

    @Test("restore entry points rebuild every derived cache")
    func restoreEntryPointsRebuildEveryDerivedCache() {
        let remotePane = TerminalPane(
            title: "ed@remote.example",
            workingDirectory: "~",
            remoteHost: "remote.example",
            agentKind: .codex,
            agentExecutionState: .thinking,
            unreadNotificationCount: 3,
            executionPlan: .local
        )
        let replacement = TerminalSession(
            title: "replacement",
            workingDirectory: "~",
            layout: .pane(remotePane),
            activePaneID: remotePane.id
        )
        let snapshot = SessionSnapshot(
            groups: [SessionGroup(name: "remote", sessions: [replacement])],
            selectedSessionID: replacement.id
        )

        let restored = SessionStore(restoring: snapshot)
        assertDerivedCachesMatchOracle(restored)

        let original = makeSession("original", unreadNotificationCount: 2)
        let replaced = SessionStore(
            groups: [SessionGroup(name: "main", sessions: [original])],
            selectedSessionID: original.id
        )
        replaced.replaceState(restoring: snapshot)
        #expect(replaced.selectedSessionID == replacement.id)
        assertDerivedCachesMatchOracle(replaced)
    }

    @Test("reopen rebuilds caches for the newly minted workspace")
    func reopenRebuildsCachesForNewWorkspace() throws {
        let session = makeSession("closed", agentKind: .codex, agentState: .thinking)
        let store = SessionStore(
            groups: [SessionGroup(name: "main", sessions: [session])],
            selectedSessionID: session.id
        )

        store.closeSession(id: session.id)
        let reopenedID = try #require(store.reopenMostRecentlyClosed())

        #expect(reopenedID != session.id)
        #expect(store.selectedSessionID == reopenedID)
        assertDerivedCachesMatchOracle(store)
    }

    @Test("remote title and pwd updates patch remote pane membership")
    func remoteUpdatesPatchRemotePaneMembership() {
        let session = makeSession("shell")
        let store = SessionStore(groups: [SessionGroup(name: "main", sessions: [session])])
        let paneID = session.activePaneID

        store.updatePane(
            sessionID: session.id,
            paneID: paneID,
            title: "ed@definitely-remote.invalid"
        )
        #expect(store.index.remotePaneIDs == [paneID])
        assertDerivedCachesMatchOracle(store)

        store.updatePane(
            sessionID: session.id,
            paneID: paneID,
            workingDirectory: NSHomeDirectory()
        )
        #expect(store.index.remotePaneIDs.isEmpty)
        assertDerivedCachesMatchOracle(store)
    }

    @Test("runtime event commits unread and risk without cache drift")
    func runtimeEventCommitsUnreadAndRisk() {
        let session = makeSession("agent", agentKind: .codex, agentState: .thinking)
        let store = SessionStore(groups: [SessionGroup(name: "main", sessions: [session])])

        let applied = store.applyAgentRuntimeEvent(
            AgentRuntimeEvent(
                source: .codex,
                executionState: .waiting,
                phase: .stop,
                eventID: "turn-complete"
            ),
            to: session.id,
            paneID: session.activePaneID,
            terminalIsFocused: false
        )

        #expect(applied)
        #expect(store.unreadNotificationTotal == 1)
        assertDerivedCachesMatchOracle(store)
    }

    @Test("runtime open-document rebuild preserves derived caches")
    func runtimeOpenDocumentRebuildPreservesDerivedCaches() {
        let session = makeSession(
            "agent",
            agentKind: .codex,
            agentState: .thinking,
            unreadNotificationCount: 2
        )
        let store = SessionStore(groups: [SessionGroup(name: "main", sessions: [session])])

        let applied = store.applyAgentRuntimeEvent(
            AgentRuntimeEvent(
                source: .codex,
                phase: .openDocument,
                eventID: "open-document",
                documentPath: "/tmp/f30-runtime-oracle.md"
            ),
            to: session.id,
            paneID: session.activePaneID
        )

        #expect(applied)
        #expect(store.session(id: session.id)?.layout.firstDocumentGroup != nil)
        #expect(store.unreadNotificationTotal == 2)
        assertDerivedCachesMatchOracle(store)
    }

    // MARK: - Attention / risk / remote (PR3)

    @Test("acknowledgeSession patches unread via commit")
    func acknowledgeSessionPatchesUnread() {
        let session = makeSession("noisy", unreadNotificationCount: 3)
        let store = SessionStore(groups: [SessionGroup(name: "main", sessions: [session])])
        #expect(store.unreadNotificationTotal == 3)

        store.acknowledgeSession(id: session.id)

        #expect(store.unreadNotificationTotal == 0)
        assertDerivedCachesMatchOracle(store)
    }

    @Test("updateTerminalQuitConfirmationRisks reclassifies via commit")
    func quitConfirmationRisksReclassifyViaCommit() {
        let session = makeSession("shell")
        let store = SessionStore(groups: [SessionGroup(name: "main", sessions: [session])])
        #expect(store.sessionsAtRiskOnQuit.isEmpty)

        store.updateTerminalQuitConfirmationRisks([
            TerminalQuitConfirmationSnapshot(
                sessionID: session.id,
                paneID: session.activePaneID,
                needsConfirmation: true
            )
        ])

        #expect(store.sessionsAtRiskOnQuit.map(\.id) == [session.id])
        assertDerivedCachesMatchOracle(store)
    }

    @Test("markAgentActivityObserved does not reclassify risk (INT-420)")
    func markAgentActivityObservedDoesNotReclassify() {
        let stale = Date().addingTimeInterval(-(TerminalSession.staleAgentActivityThreshold + 5))
        let session = TerminalSession(
            title: "long thinker",
            workingDirectory: "~",
            agentKind: .codex,
            agentState: .thinking,
            lastAgentStateChangeAt: stale
        )
        let store = SessionStore(groups: [SessionGroup(name: "main", sessions: [session])])
        let durableBefore = store.index.durableAtRiskSessionIDs
        let freshnessBefore = store.index.freshnessCandidateSessionIDs

        store.markAgentActivityObserved(id: session.id)

        // Membership sets are unchanged; only the live timestamp on the pane moved.
        #expect(store.index.durableAtRiskSessionIDs == durableBefore)
        #expect(store.index.freshnessCandidateSessionIDs == freshnessBefore)
        // Freshness now makes the session at risk when evaluated at "now".
        #expect(store.sessionsAtRiskOnQuit.map(\.id) == [session.id])
    }

    @Test("fresh agent activity does not publish groups")
    func freshAgentActivityDoesNotPublishGroups() {
        let session = makeSession("fresh", agentKind: .codex, agentState: .thinking)
        let store = SessionStore(groups: [SessionGroup(name: "main", sessions: [session])])
        let published = LockedFlag()

        withObservationTracking {
            _ = store.groups
        } onChange: {
            published.set()
        }

        store.markAgentActivityObserved(id: session.id)
        #expect(!published.value)
    }

    @Test("unchanged shell activity does not publish groups")
    func unchangedShellActivityDoesNotPublishGroups() {
        let session = makeSession("shell")
        let store = SessionStore(groups: [SessionGroup(name: "main", sessions: [session])])
        let published = LockedFlag()

        withObservationTracking {
            _ = store.groups
        } onChange: {
            published.set()
        }

        let pending = store.updateShellActivity([])
        #expect(!pending)
        #expect(!published.value)
    }

    @Test("same-value selection commit still publishes")
    func sameValueSelectionCommitStillPublishes() {
        let session = makeSession("selected")
        let store = SessionStore(
            groups: [SessionGroup(name: "main", sessions: [session])],
            selectedSessionID: session.id
        )
        let published = LockedFlag()

        withObservationTracking {
            _ = store.selectedSessionID
        } onChange: {
            published.set()
        }

        store.commit(WorkspaceMutationEffect(selection: .set(session.id)))
        #expect(published.value)
    }

    // MARK: - renameGroup (no-commit pilot)

    @Test("renameGroup does not rebuild derived caches")
    func renameGroupIsNoCommitFamily() {
        let first = makeSession("first", unreadNotificationCount: 2)
        let second = makeSession(
            "second",
            agentKind: .codex,
            agentState: .thinking,
            unreadNotificationCount: 1
        )
        let group = SessionGroup(name: "main", sessions: [first, second])
        let store = SessionStore(
            groups: [group],
            selectedSessionID: second.id,
            pinnedSessionIDs: [first.id]
        )

        let positionsBefore = store.index.positionsBySessionID
        let unreadBefore = store.unreadNotificationTotal
        let liveBefore = store.index.livePaneIDs
        let durableBefore = store.index.durableAtRiskSessionIDs
        let freshnessBefore = store.index.freshnessCandidateSessionIDs
        let pinsBefore = store.pinnedSessionIDs
        let selectedBefore = store.selectedSessionID

        let renamed = store.renameGroup(id: group.id, to: "renamed")
        #expect(renamed)
        #expect(store.groups[0].name == "renamed")

        // No-commit: every derived cache must be bitwise identical.
        #expect(store.index.positionsBySessionID == positionsBefore)
        #expect(store.unreadNotificationTotal == unreadBefore)
        #expect(store.index.livePaneIDs == liveBefore)
        #expect(store.index.durableAtRiskSessionIDs == durableBefore)
        #expect(store.index.freshnessCandidateSessionIDs == freshnessBefore)
        #expect(store.pinnedSessionIDs == pinsBefore)
        #expect(store.selectedSessionID == selectedBefore)
        assertDerivedCachesMatchOracle(store)
    }

    // MARK: - Helpers

    private func makeSession(
        _ title: String,
        agentKind: AgentKind = .shell,
        agentState: AgentState = .idle,
        unreadNotificationCount: Int = 0
    ) -> TerminalSession {
        TerminalSession(
            title: title,
            workingDirectory: "~",
            agentKind: agentKind,
            agentState: agentState,
            unreadNotificationCount: unreadNotificationCount
        )
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        lock.withLock { storage }
    }

    func set() {
        lock.withLock { storage = true }
    }
}
