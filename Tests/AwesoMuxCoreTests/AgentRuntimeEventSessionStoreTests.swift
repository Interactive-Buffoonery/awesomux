import AwesoMuxBridgeProtocol
import Foundation
import Testing
@testable import AwesoMuxCore

@MainActor
@Suite
struct AgentRuntimeEventSessionStoreTests {
    private func makeSession(
        kind: AgentKind = .shell,
        state: AgentState = .running,
        lastAgentStateChangeAt: Date = Date(),
        unreadNotificationCount: Int = 0
    ) -> TerminalSession {
        TerminalSession(
            title: "workspace",
            workingDirectory: "~",
            agentKind: kind,
            agentState: state,
            lastAgentStateChangeAt: lastAgentStateChangeAt,
            unreadNotificationCount: unreadNotificationCount
        )
    }

    private func makeStore(_ sessions: TerminalSession...) -> SessionStore {
        SessionStore(groups: [SessionGroup(name: "main", sessions: sessions)])
    }

    @Test
    func claudeToolEndRecordsTouchedPathIntoRecentLinks() {
        // issue #175: an agent-written Markdown path reaches the recent-links
        // surface via the side channel even though the console output was
        // hard-wrapped and un-clickable. End-to-end through the reducer + facade.
        let session = makeSession(kind: .claudeCode, state: .running)
        let store = makeStore(session)
        let paneID = session.activePaneID

        store.applyAgentRuntimeEvent(
            AgentRuntimeEvent(source: .claudeCode, phase: .sessionStart),
            to: session.id,
            paneID: paneID
        )
        let applied = store.applyAgentRuntimeEvent(
            AgentRuntimeEvent(
                source: .claudeCode,
                executionState: .thinking,
                phase: .toolEnd,
                touchedPath: "/Users/agent/plan.md"
            ),
            to: session.id,
            paneID: paneID
        )

        #expect(applied)
        #expect(
            store.session(id: session.id)?.activePane?.recentLinks.values
                == ["/Users/agent/plan.md"]
        )
    }

    @Test
    func toolEndWithoutTouchedPathLeavesRecentLinksEmpty() {
        let session = makeSession(kind: .claudeCode, state: .running)
        let store = makeStore(session)

        store.applyAgentRuntimeEvent(
            AgentRuntimeEvent(source: .claudeCode, executionState: .thinking, phase: .toolEnd),
            to: session.id,
            paneID: session.activePaneID
        )

        #expect(store.session(id: session.id)?.activePane?.recentLinks.values.isEmpty == true)
    }

    @Test
    func updatesAgentKindFromEvent() {
        let session = makeSession()
        let store = makeStore(session)

        let applied = store.applyAgentRuntimeEvent(
            AgentRuntimeEvent(source: .claudeCode, kind: .claudeCode),
            to: session.id,
            paneID: session.activePaneID
        )

        #expect(applied)
        #expect(store.session(id: session.id)?.agentKind == .claudeCode)
    }

    @Test
    func eventSourcedProcessErrorIsNormalizedToUnknownSoTheGenericAnnouncementStillFires() {
        // INT-642 dedup soundness: .processError is reserved for the internal
        // sibling-pane-exit path, whose specific VoiceOver announcement the
        // workspace attention tracker dedups against. An event-file writer
        // claiming .processError gets NO specific announcement, so the reducer
        // must normalize it to .unknown — keeping the generic tracker
        // announcement as the transition's only (and required) announcement.
        let selected = makeSession()
        let background = makeSession(kind: .codex)
        let store = makeStore(selected, background)
        var tracker = WorkspaceAttentionAnnouncementTracker(groups: store.groups)

        store.applyAgentRuntimeEvent(
            AgentRuntimeEvent(source: .codex, attentionReason: .processError),
            to: background.id,
            paneID: background.activePaneID,
            terminalIsFocused: false
        )

        #expect(
            store.session(id: background.id)?.activePane?.attentionReason == .unknown
        )
        let announcements = tracker.announcements(
            afterUpdating: store.groups,
            selectedSessionID: selected.id,
            isAppActive: true
        )
        #expect(announcements.count == 1)
        #expect(announcements.first?.state == .needsAttention)
    }

    @Test
    func updatesAgentStateFromEvent() {
        let session = makeSession(kind: .claudeCode)
        let store = makeStore(session)

        store.applyAgentRuntimeEvent(
            AgentRuntimeEvent(source: .claudeCode, state: .waiting),
            to: session.id,
            paneID: session.activePaneID
        )

        #expect(store.session(id: session.id)?.agentState == .waiting)
        #expect(store.session(id: session.id)?.agentExecutionState == .waiting)
    }

    @Test
    func eventWithoutKindOnNonShellSessionPreservesExistingKind() {
        let session = makeSession(kind: .codex)
        let store = makeStore(session)

        store.applyAgentRuntimeEvent(
            AgentRuntimeEvent(source: .claudeCode, state: .thinking),
            to: session.id,
            paneID: session.activePaneID
        )

        #expect(store.session(id: session.id)?.agentKind == .codex)
    }

    @Test
    func eventWithoutKindOnShellSessionInfersKindFromSource() {
        let session = makeSession()
        let store = makeStore(session)

        store.applyAgentRuntimeEvent(
            AgentRuntimeEvent(source: .claudeCode, state: .thinking),
            to: session.id,
            paneID: session.activePaneID
        )

        #expect(store.session(id: session.id)?.agentKind == .claudeCode)
        #expect(store.session(id: session.id)?.agentState == .thinking)
        #expect(store.session(id: session.id)?.agentExecutionState == .thinking)
    }

    @Test
    func eventWithoutStatePreservesExistingState() {
        let session = makeSession(state: .output)
        let store = makeStore(session)

        store.applyAgentRuntimeEvent(
            AgentRuntimeEvent(source: .claudeCode, kind: .claudeCode),
            to: session.id,
            paneID: session.activePaneID
        )

        #expect(store.session(id: session.id)?.agentState == .output)
        #expect(store.session(id: session.id)?.agentExecutionState == .output)
    }

    @Test
    func needsAttentionIncrementsUnreadWhenUnfocused() {
        let session = makeSession(kind: .claudeCode, state: .thinking)
        let store = makeStore(session)

        store.applyAgentRuntimeEvent(
            AgentRuntimeEvent(source: .claudeCode, state: .needsAttention),
            to: session.id,
            paneID: session.activePaneID,
            terminalIsFocused: false
        )

        #expect(store.session(id: session.id)?.unreadNotificationCount == 1)
        #expect(store.session(id: session.id)?.agentExecutionState == .thinking)
        #expect(store.session(id: session.id)?.attentionReason == .unknown)
    }

    @Test
    func repeatedNeedsAttentionDoesNotIncrementUnreadAgain() {
        let session = makeSession(
            kind: .claudeCode,
            state: .needsAttention,
            unreadNotificationCount: 1
        )
        let store = makeStore(session)

        store.applyAgentRuntimeEvent(
            AgentRuntimeEvent(source: .claudeCode, state: .needsAttention),
            to: session.id,
            paneID: session.activePaneID,
            terminalIsFocused: false
        )

        #expect(store.session(id: session.id)?.unreadNotificationCount == 1)
    }

    @Test
    func waitingClearsAttentionDisplayButKeepsUnreadBadge() {
        // The headline contract of the execution/attention split: when a session
        // goes loud (`.needsAttention`, badge accrues while unfocused) and then
        // the agent settles to a quiet execution state (`.waiting`), the
        // ATTENTION OVERLAY clears (display reverts to `.waiting`) but the unread
        // BADGE PERSISTS. The badge is user-owned and cleared only by
        // acknowledgement — never by a runtime state transition. (This is the
        // deliberate inverse of the parked INT-360 "waiting clears the badge"
        // behavior; see INT-167.)
        let session = makeSession(kind: .claudeCode, state: .thinking)
        let store = makeStore(session)

        store.applyAgentRuntimeEvent(
            AgentRuntimeEvent(source: .claudeCode, state: .needsAttention),
            to: session.id,
            paneID: session.activePaneID,
            terminalIsFocused: false
        )
        #expect(store.session(id: session.id)?.unreadNotificationCount == 1)
        #expect(store.session(id: session.id)?.agentState == .needsAttention)

        store.applyAgentRuntimeEvent(
            AgentRuntimeEvent(source: .claudeCode, state: .waiting),
            to: session.id,
            paneID: session.activePaneID,
            terminalIsFocused: false
        )

        // Overlay cleared, execution advanced — but the badge survives.
        #expect(store.session(id: session.id)?.attentionReason == nil)
        #expect(store.session(id: session.id)?.agentExecutionState == .waiting)
        #expect(store.session(id: session.id)?.agentState == .waiting)
        #expect(store.session(id: session.id)?.unreadNotificationCount == 1)
        #expect(store.unreadNotificationTotal == 1)
    }

    @Test
    func dualFieldEventWithLegacyExecutionStateClearsAttention() {
        // Both-present compat rule (load-bearing, easy to flip by accident):
        // when an event carries BOTH a modern `executionState` AND a legacy
        // `state` whose executionState is non-nil, the durable value comes from
        // `executionState` but `clearsAttention` keys off the legacy `state`,
        // so a pending overlay is cleared. (executionState: .thinking +
        // state: .waiting → execution .thinking, attention cleared.)
        let session = makeSession(
            kind: .claudeCode,
            state: .needsAttention,
            unreadNotificationCount: 1
        )
        let store = makeStore(session)

        store.applyAgentRuntimeEvent(
            AgentRuntimeEvent(source: .claudeCode, executionState: .thinking, state: .waiting),
            to: session.id,
            paneID: session.activePaneID
        )

        let updated = store.session(id: session.id)
        #expect(updated?.agentExecutionState == .thinking)
        #expect(updated?.attentionReason == nil)
        #expect(updated?.agentState == .thinking)
    }

    @Test
    func dualFieldEventWithLegacyNeedsAttentionKeepsAttentionOverModernExecution() {
        // The mirror case: executionState: .thinking + state: .needsAttention.
        // `.needsAttention` has no executionState, so `clearsAttention` is false;
        // the durable execution advances to `.thinking` AND the attention overlay
        // is set (.unknown from the legacy needsAttention), so the display still
        // projects to `.needsAttention`. Pins that a modern execution value can
        // coexist with a legacy attention signal in one event.
        let session = makeSession(kind: .claudeCode, state: .running)
        let store = makeStore(session)

        store.applyAgentRuntimeEvent(
            AgentRuntimeEvent(source: .claudeCode, executionState: .thinking, state: .needsAttention),
            to: session.id,
            paneID: session.activePaneID,
            terminalIsFocused: false
        )

        let updated = store.session(id: session.id)
        #expect(updated?.agentExecutionState == .thinking)
        #expect(updated?.attentionReason == .unknown)
        #expect(updated?.agentState == .needsAttention)
        #expect(updated?.unreadNotificationCount == 1)
    }

    @Test
    func needsAttentionDoesNotIncrementUnreadWhenFocused() {
        let session = makeSession(kind: .claudeCode, state: .thinking)
        let store = makeStore(session)

        store.applyAgentRuntimeEvent(
            AgentRuntimeEvent(source: .claudeCode, state: .needsAttention),
            to: session.id,
            paneID: session.activePaneID,
            terminalIsFocused: true
        )

        #expect(store.session(id: session.id)?.unreadNotificationCount == 0)
    }

    @Test
    func repeatedActiveStateRefreshesLastAgentStateChangeAt() {
        let staleActivityDate = Date().addingTimeInterval(
            -TerminalSession.staleAgentActivityThreshold - 1
        )
        let session = makeSession(
            kind: .claudeCode,
            state: .thinking,
            lastAgentStateChangeAt: staleActivityDate
        )
        let store = makeStore(session)

        #expect(store.session(id: session.id)?.isQuitRisk() == false)

        store.applyAgentRuntimeEvent(
            AgentRuntimeEvent(source: .claudeCode, state: .thinking),
            to: session.id,
            paneID: session.activePaneID
        )

        let updated = store.session(id: session.id)
        #expect((updated?.lastAgentStateChangeAt ?? staleActivityDate) > staleActivityDate)
        #expect(updated?.isQuitRisk() == true)
    }

    @Test
    func waitingIsAcceptedAndQuiet() {
        let session = makeSession(kind: .claudeCode, state: .thinking)
        let store = makeStore(session)

        store.applyAgentRuntimeEvent(
            AgentRuntimeEvent(source: .claudeCode, state: .waiting),
            to: session.id,
            paneID: session.activePaneID
        )

        #expect(store.session(id: session.id)?.agentState == .waiting)
        #expect(store.session(id: session.id)?.agentExecutionState == .waiting)
        #expect(store.session(id: session.id)?.unreadNotificationCount == 0)
    }

    @Test
    func openDocumentEventOpensDocumentInRequestingSessionWithoutStateMutation() throws {
        let selected = makeSession(kind: .shell, state: .running)
        let requesting = makeSession(kind: .codex, state: .waiting, unreadNotificationCount: 1)
        let store = makeStore(selected, requesting)

        let applied = store.applyAgentRuntimeEvent(
            AgentRuntimeEvent(
                source: .codex,
                kind: .codex,
                phase: .openDocument,
                eventID: "open-doc",
                documentPath: "/tmp/notes.md",
                timestamp: Date(timeIntervalSince1970: 10)
            ),
            to: requesting.id,
            paneID: requesting.activePaneID
        )

        #expect(applied)
        #expect(documentPaneCount(store.session(id: selected.id)?.layout) == 0)
        let updated = try #require(store.session(id: requesting.id))
        #expect(documentPaneCount(updated.layout) == 1)
        #expect(documentPaneURLs(updated.layout) == [URL(fileURLWithPath: "/tmp/notes.md").standardizedFileURL])
        #expect(updated.activePaneID == requesting.activePaneID)
        #expect(updated.agentKind == .codex)
        #expect(updated.agentState == .waiting)
        #expect(updated.agentExecutionState == .waiting)
        #expect(updated.attentionReason == nil)
        #expect(updated.unreadNotificationCount == 1)
    }

    @Test
    func duplicateOpenDocumentEventIsDroppedWithoutDuplicatingPane() {
        let session = makeSession(kind: .codex, state: .waiting)
        let store = makeStore(session)
        let event = AgentRuntimeEvent(
            source: .codex,
            phase: .openDocument,
            eventID: "open-doc",
            documentPath: "/tmp/notes.md",
            timestamp: Date(timeIntervalSince1970: 10)
        )

        let firstApplied = store.applyAgentRuntimeEvent(event, to: session.id, paneID: session.activePaneID)
        let secondApplied = store.applyAgentRuntimeEvent(event, to: session.id, paneID: session.activePaneID)

        #expect(firstApplied)
        #expect(!secondApplied)
        #expect(documentPaneCount(store.session(id: session.id)?.layout) == 1)
    }

    @Test(arguments: [
        "notes.md",
        "/tmp/notes.txt",
        "/tmp/notes.md\u{0}suffix",
    ])
    func invalidOpenDocumentEventDoesNotOpenPane(path: String) {
        let session = makeSession(kind: .codex, state: .waiting)
        let store = makeStore(session)

        let applied = store.applyAgentRuntimeEvent(
            AgentRuntimeEvent(source: .codex, phase: .openDocument, documentPath: path),
            to: session.id,
            paneID: session.activePaneID
        )

        #expect(!applied)
        #expect(documentPaneCount(store.session(id: session.id)?.layout) == 0)
    }

    @Test
    func duplicateEventIDIsDroppedAndStatePreserved() {
        let session = makeSession(kind: .claudeCode, state: .thinking)
        let store = makeStore(session)

        let firstApplied = store.applyAgentRuntimeEvent(
            AgentRuntimeEvent(source: .claudeCode, state: .needsAttention, eventID: "evt-1"),
            to: session.id,
            paneID: session.activePaneID,
            terminalIsFocused: false
        )
        let secondApplied = store.applyAgentRuntimeEvent(
            AgentRuntimeEvent(source: .claudeCode, state: .thinking, eventID: "evt-1"),
            to: session.id,
            paneID: session.activePaneID
        )

        #expect(firstApplied)
        #expect(!secondApplied)
        #expect(store.session(id: session.id)?.agentState == .needsAttention)
        #expect(store.session(id: session.id)?.agentExecutionState == .thinking)
        #expect(store.session(id: session.id)?.attentionReason == .unknown)
        #expect(store.session(id: session.id)?.unreadNotificationCount == 1)
    }

    @Test
    func staleTimestampIsRejected() {
        let session = makeSession(kind: .claudeCode)
        let store = makeStore(session)

        let fresh = Date()
        let stale = fresh.addingTimeInterval(-10)
        store.applyAgentRuntimeEvent(
            AgentRuntimeEvent(source: .claudeCode, state: .needsAttention, timestamp: fresh),
            to: session.id,
            paneID: session.activePaneID,
            terminalIsFocused: false
        )
        let staleApplied = store.applyAgentRuntimeEvent(
            AgentRuntimeEvent(source: .claudeCode, state: .thinking, timestamp: stale),
            to: session.id,
            paneID: session.activePaneID
        )

        #expect(!staleApplied)
        #expect(store.session(id: session.id)?.agentState == .needsAttention)
        #expect(store.session(id: session.id)?.agentExecutionState == .running)
    }

    @Test
    func equalTimestampIsRejectedAsStaleTieBreak() {
        // Two events with the same timestamp can arrive in either order
        // when adapters emit second-precision Unix timestamps. Treat the
        // second as stale so out-of-order pairs can't swap state.
        let session = makeSession(kind: .claudeCode)
        let store = makeStore(session)

        let ts = Date()
        store.applyAgentRuntimeEvent(
            AgentRuntimeEvent(source: .claudeCode, state: .needsAttention, timestamp: ts),
            to: session.id,
            paneID: session.activePaneID,
            terminalIsFocused: false
        )
        let secondApplied = store.applyAgentRuntimeEvent(
            AgentRuntimeEvent(source: .claudeCode, state: .thinking, timestamp: ts),
            to: session.id,
            paneID: session.activePaneID
        )

        #expect(!secondApplied)
        #expect(store.session(id: session.id)?.agentState == .needsAttention)
    }

    @Test
    func missingSessionIsNoop() {
        let session = makeSession()
        let store = makeStore(session)

        let applied = store.applyAgentRuntimeEvent(
            AgentRuntimeEvent(source: .claudeCode, kind: .claudeCode, state: .waiting),
            to: UUID(),
            paneID: UUID()
        )

        #expect(!applied)
        #expect(store.session(id: session.id) == session)
    }

    @Test
    func sameEventIDWithDifferentTimestampIsAccepted() {
        // Adapters that reuse eventID counters across turns (counter
        // resets to "1" each restart) emit valid new events with the
        // same eventID but different timestamps. The dedupe pair
        // (eventID, timestamp) must let those through.
        let session = makeSession(kind: .claudeCode, state: .thinking)
        let store = makeStore(session)

        let firstApplied = store.applyAgentRuntimeEvent(
            AgentRuntimeEvent(
                source: .claudeCode,
                state: .needsAttention,
                eventID: "1",
                timestamp: Date(timeIntervalSince1970: 1_700_000_000)
            ),
            to: session.id,
            paneID: session.activePaneID,
            terminalIsFocused: false
        )
        let secondApplied = store.applyAgentRuntimeEvent(
            AgentRuntimeEvent(
                source: .claudeCode,
                state: .thinking,
                eventID: "1",
                timestamp: Date(timeIntervalSince1970: 1_700_000_100)
            ),
            to: session.id,
            paneID: session.activePaneID
        )

        #expect(firstApplied)
        #expect(secondApplied)
        #expect(store.session(id: session.id)?.agentState == .thinking)
        #expect(store.session(id: session.id)?.agentExecutionState == .thinking)
        #expect(store.session(id: session.id)?.attentionReason == nil)
    }

    @Test
    func futureTimestampIsClampedToNowSoSubsequentEventsArentFrozen() {
        // A single bogus future-stamped event (clock skew / adapter
        // bug) must not poison the staleness cache and reject every
        // subsequent correctly-stamped event.
        let session = makeSession(kind: .claudeCode)
        let store = makeStore(session)

        let farFuture = Date().addingTimeInterval(60 * 60 * 24 * 365 * 10)  // +10y
        store.applyAgentRuntimeEvent(
            AgentRuntimeEvent(source: .claudeCode, state: .needsAttention, timestamp: farFuture),
            to: session.id,
            paneID: session.activePaneID,
            terminalIsFocused: false
        )
        // Bump the second event 1 ms past the clamped lastAppliedTimestamp.
        // Without the offset, the implementation's internal `Date()` (used
        // by the future-clamp) and the test's `Date()` here can collide on
        // the same nanosecond under parallel-suite scheduler load (CI),
        // causing the `<=` staleness gate at SessionStore.swift to reject
        // the event. The +1ms guarantees strict ordering without changing
        // production semantics. Tracked as INT-424.
        let nextApplied = store.applyAgentRuntimeEvent(
            AgentRuntimeEvent(
                source: .claudeCode,
                state: .thinking,
                timestamp: Date().addingTimeInterval(0.001)
            ),
            to: session.id,
            paneID: session.activePaneID
        )

        #expect(nextApplied)
        #expect(store.session(id: session.id)?.agentState == .thinking)
        #expect(store.session(id: session.id)?.agentExecutionState == .thinking)
        #expect(store.session(id: session.id)?.attentionReason == nil)
    }

    @Test
    func explicitAttentionReasonCoexistsWithExecutionState() {
        let session = makeSession(kind: .codex, state: .waiting)
        let store = makeStore(session)

        store.applyAgentRuntimeEvent(
            AgentRuntimeEvent(source: .codex, attentionReason: .permissionPrompt),
            to: session.id,
            paneID: session.activePaneID,
            terminalIsFocused: false
        )

        let updated = store.session(id: session.id)
        #expect(updated?.agentExecutionState == .waiting)
        #expect(updated?.attentionReason == .permissionPrompt)
        #expect(updated?.agentState == .needsAttention)
        #expect(updated?.unreadNotificationCount == 1)
    }

    @Test
    func attentionPriorityUpgradeBumpsUnreadAgain() {
        // INT-506: .bell → .permissionPrompt is a fresh notification episode —
        // the more urgent block must re-bump unread (which is what drives a
        // new macOS banner via WorkspaceNotificationTracker's baseline check).
        let session = makeSession(kind: .codex, state: .running)
        let store = makeStore(session)

        store.applyAgentRuntimeEvent(
            AgentRuntimeEvent(source: .codex, attentionReason: .bell),
            to: session.id,
            paneID: session.activePaneID,
            terminalIsFocused: false
        )
        #expect(store.session(id: session.id)?.unreadNotificationCount == 1)

        store.applyAgentRuntimeEvent(
            AgentRuntimeEvent(source: .codex, attentionReason: .permissionPrompt),
            to: session.id,
            paneID: session.activePaneID,
            terminalIsFocused: false
        )
        #expect(store.session(id: session.id)?.attentionReason == .permissionPrompt)
        #expect(store.session(id: session.id)?.unreadNotificationCount == 2)
    }

    @Test
    func sameOrLowerPriorityAttentionRepeatDoesNotRebump() {
        let session = makeSession(kind: .codex, state: .running)
        let store = makeStore(session)

        store.applyAgentRuntimeEvent(
            AgentRuntimeEvent(source: .codex, attentionReason: .permissionPrompt),
            to: session.id,
            paneID: session.activePaneID,
            terminalIsFocused: false
        )
        #expect(store.session(id: session.id)?.unreadNotificationCount == 1)

        // Same-priority repeat: no re-bump.
        store.applyAgentRuntimeEvent(
            AgentRuntimeEvent(source: .codex, attentionReason: .permissionPrompt),
            to: session.id,
            paneID: session.activePaneID,
            terminalIsFocused: false
        )
        #expect(store.session(id: session.id)?.unreadNotificationCount == 1)

        // Lower-priority arrival: reason survives, still no re-bump.
        store.applyAgentRuntimeEvent(
            AgentRuntimeEvent(source: .codex, attentionReason: .bell),
            to: session.id,
            paneID: session.activePaneID,
            terminalIsFocused: false
        )
        #expect(store.session(id: session.id)?.attentionReason == .permissionPrompt)
        #expect(store.session(id: session.id)?.unreadNotificationCount == 1)
    }

    @Test
    func splitExecutionStateDoesNotClearAttention() {
        let session = TerminalSession(
            title: "workspace",
            workingDirectory: "~",
            agentKind: .codex,
            agentExecutionState: .waiting,
            attentionReason: .permissionPrompt
        )
        let store = makeStore(session)

        store.applyAgentRuntimeEvent(
            AgentRuntimeEvent(source: .codex, executionState: .thinking),
            to: session.id,
            paneID: session.activePaneID,
            terminalIsFocused: false
        )

        let updated = store.session(id: session.id)
        #expect(updated?.agentExecutionState == .thinking)
        #expect(updated?.attentionReason == .permissionPrompt)
        #expect(updated?.agentState == .needsAttention)
        #expect(updated?.unreadNotificationCount == 0)
    }

    @Test
    func acknowledgementClearsAttentionAndPreservesExecutionState() {
        let session = makeSession(kind: .codex, state: .waiting)
        let store = makeStore(session)

        store.applyAgentRuntimeEvent(
            AgentRuntimeEvent(source: .codex, attentionReason: .bell),
            to: session.id,
            paneID: session.activePaneID,
            terminalIsFocused: false
        )

        store.acknowledgeSession(id: session.id)

        let updated = store.session(id: session.id)
        #expect(updated?.agentExecutionState == .waiting)
        #expect(updated?.attentionReason == nil)
        #expect(updated?.agentState == .waiting)
        #expect(updated?.unreadNotificationCount == 0)
    }

    @Test
    func paneScopedDedupeAllowsSameEventIDOnDifferentPanes() {
        // Split sessions emit events independently per pane and may
        // legitimately reuse eventID values across panes. The dedupe
        // cache must be pane-scoped so a second pane's event is not
        // mistakenly dropped as a duplicate of the first pane's.
        let paneA = TerminalPane(title: "a", workingDirectory: "~", executionPlan: .local)
        let paneB = TerminalPane(title: "b", workingDirectory: "~", executionPlan: .local)
        let layout = TerminalPaneLayout.split(
            TerminalSplit(orientation: .horizontal, first: .pane(paneA), second: .pane(paneB))
        )
        let session = TerminalSession(
            title: "split",
            workingDirectory: "~",
            agentKind: .claudeCode,
            agentState: .thinking,
            layout: layout
        )
        let store = makeStore(session)

        let firstApplied = store.applyAgentRuntimeEvent(
            AgentRuntimeEvent(source: .claudeCode, state: .needsAttention, eventID: "evt-1"),
            to: session.id,
            paneID: paneA.id,
            terminalIsFocused: false
        )
        let secondApplied = store.applyAgentRuntimeEvent(
            AgentRuntimeEvent(source: .claudeCode, state: .needsAttention, eventID: "evt-1"),
            to: session.id,
            paneID: paneB.id,
            terminalIsFocused: false
        )

        #expect(firstApplied)
        #expect(secondApplied)
    }

    // MARK: - INT-552 synthetic liveness-detector reset

    /// The exact event shape `detectAgentExitedToShell()` synthesizes when an
    /// agent exits inside a living shell. Pins the composition seam: this
    /// minimal event (no eventID, no timestamp, `.unknown` source) must fully
    /// reset the pane's agent chrome through the standard store entry point.
    @Test
    func syntheticLivenessSessionEndResetsAgentChrome() {
        let session = makeSession()
        let store = makeStore(session)
        store.applyAgentRuntimeEvent(
            AgentRuntimeEvent(source: .openCode, state: .needsAttention),
            to: session.id,
            paneID: session.activePaneID,
            terminalIsFocused: false
        )
        #expect(store.session(id: session.id)?.agentKind == .openCode)
        #expect(store.session(id: session.id)?.unreadNotificationCount == 1)

        let applied = store.applyAgentRuntimeEvent(
            AgentRuntimeEvent(source: .unknown, executionState: .idle, phase: .sessionEnd),
            to: session.id,
            paneID: session.activePaneID
        )

        #expect(applied)
        #expect(store.session(id: session.id)?.agentKind == .shell)
        #expect(store.session(id: session.id)?.agentExecutionState == .idle)
        #expect(store.session(id: session.id)?.attentionReason == nil)
        #expect(store.session(id: session.id)?.unreadNotificationCount == 0)
    }

    /// Restarting an agent in the same pane after a synthetic reset must
    /// restore the kind: the reducer's post-exit latch is cleared by the new
    /// session's `sessionStart`, which re-infers the kind from the source.
    @Test
    func agentRestartAfterSyntheticResetRestoresKind() {
        let session = makeSession(kind: .openCode, state: .waiting)
        let store = makeStore(session)

        store.applyAgentRuntimeEvent(
            AgentRuntimeEvent(source: .unknown, executionState: .idle, phase: .sessionEnd),
            to: session.id,
            paneID: session.activePaneID
        )
        #expect(store.session(id: session.id)?.agentKind == .shell)

        store.applyAgentRuntimeEvent(
            AgentRuntimeEvent(source: .openCode, executionState: .idle, phase: .sessionStart),
            to: session.id,
            paneID: session.activePaneID
        )

        #expect(store.session(id: session.id)?.agentKind == .openCode)
        #expect(store.session(id: session.id)?.agentExecutionState == .idle)
    }

    private func documentPaneCount(_ layout: TerminalPaneLayout?) -> Int {
        layout?.firstDocumentGroup?.tabs.count ?? 0
    }

    private func documentPaneURLs(_ layout: TerminalPaneLayout) -> [URL] {
        layout.firstDocumentGroup?.tabs.map(\.fileURL) ?? []
    }
}
