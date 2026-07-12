import Foundation
import Testing
@testable import AwesoMuxCore

/// Pins the runtime-event → waiting-announcement contract (INT-419) against
/// real hook event shapes (see `AgentHookEventMapper`), by composing
/// `SessionStore.applyAgentRuntimeEvent` with the same per-pane prior/new
/// display reads the surface layer performs before calling
/// `announcementIntent`. Uses a real split so the pane-vs-session scoping
/// (INT-504) is exercised, not just the active pane.
@MainActor
@Suite("Waiting announcement over runtime events")
struct WaitingAnnouncementRuntimeEventTests {
    private let reducer = VisibleTextAgentStateReducer()

    /// Mirrors the surface layer's announce seam: read the target pane's
    /// display state, apply the event, read again, derive the intent.
    private func intentAfterApplying(
        _ event: AgentRuntimeEvent,
        store: SessionStore,
        sessionID: TerminalSession.ID,
        paneID: TerminalPane.ID
    ) -> AgentStateAnnouncementIntent {
        let prior = store.session(id: sessionID)?.layout.pane(id: paneID)?.agentState
        guard store.applyAgentRuntimeEvent(event, to: sessionID, paneID: paneID) else {
            return .none
        }
        let new = store.session(id: sessionID)?.layout.pane(id: paneID)?.agentState
        return reducer.announcementIntent(priorDisplayState: prior, newDisplayState: new)
    }

    /// "idle_prompt" Notification shape: executionState .waiting, no attention.
    private func idlePromptEvent(at timestamp: Date) -> AgentRuntimeEvent {
        AgentRuntimeEvent(
            source: .claudeCode,
            executionState: .waiting,
            phase: .notification,
            eventID: UUID().uuidString,
            timestamp: timestamp
        )
    }

    private func makeSplitStore(
        paneA: TerminalPane,
        paneB: TerminalPane
    ) -> (SessionStore, TerminalSession) {
        let session = TerminalSession(
            title: "split",
            workingDirectory: "/tmp/a",
            layout: .split(TerminalSplit(
                orientation: .vertical,
                first: .pane(paneA),
                second: .pane(paneB),
                firstFraction: 0.5
            )),
            activePaneID: paneA.id
        )
        let store = SessionStore(groups: [SessionGroup(name: "main", sessions: [session])])
        return (store, session)
    }

    @Test("idle-prompt waiting announces for the event's pane only in a split")
    func idlePromptAnnouncesForEventPaneOnlyInSplit() {
        let paneA = TerminalPane(
            title: "agent",
            workingDirectory: "/tmp/a",
            agentKind: .claudeCode,
            agentExecutionState: .running
        )
        let paneB = TerminalPane(
            title: "sibling",
            workingDirectory: "/tmp/b",
            agentKind: .claudeCode,
            agentExecutionState: .error
        )
        let (store, session) = makeSplitStore(paneA: paneA, paneB: paneB)

        let intent = intentAfterApplying(
            idlePromptEvent(at: Date()),
            store: store,
            sessionID: session.id,
            paneID: paneA.id
        )

        #expect(intent == .waitingEntered)
        #expect(store.session(id: session.id)?.layout.pane(id: paneA.id)?.agentState == .waiting)
        // The sibling's louder pane-level state is untouched — the per-pane
        // read/apply/read never consults the session-level rollup (INT-504).
        #expect(store.session(id: session.id)?.layout.pane(id: paneB.id)?.agentState == .error)
    }

    @Test("Stop turn-end displays waiting and announces waiting")
    func stopTurnEndAnnouncesWaiting() {
        let pane = TerminalPane(
            title: "agent",
            workingDirectory: "/tmp/a",
            agentKind: .claudeCode,
            agentExecutionState: .thinking
        )
        let sibling = TerminalPane(title: "sibling", workingDirectory: "/tmp/b")
        let (store, session) = makeSplitStore(paneA: pane, paneB: sibling)

        // Claude Code "Stop" shape after INT-650: turn-end rests directly on
        // waiting; unread/notification is separate from the attention overlay.
        let stopEvent = AgentRuntimeEvent(
            source: .claudeCode,
            executionState: .waiting,
            phase: .stop,
            eventID: UUID().uuidString,
            timestamp: Date()
        )
        let intent = intentAfterApplying(
            stopEvent,
            store: store,
            sessionID: session.id,
            paneID: pane.id
        )

        #expect(store.session(id: session.id)?.layout.pane(id: pane.id)?.agentState
            == .waiting)
        #expect(intent == .waitingEntered)
    }

    @Test("repeated waiting events announce once")
    func repeatedWaitingEventsAnnounceOnce() {
        let pane = TerminalPane(
            title: "agent",
            workingDirectory: "/tmp/a",
            agentKind: .claudeCode,
            agentExecutionState: .running
        )
        let sibling = TerminalPane(title: "sibling", workingDirectory: "/tmp/b")
        let (store, session) = makeSplitStore(paneA: pane, paneB: sibling)
        let base = Date()

        let first = intentAfterApplying(
            idlePromptEvent(at: base),
            store: store,
            sessionID: session.id,
            paneID: pane.id
        )
        let second = intentAfterApplying(
            idlePromptEvent(at: base.addingTimeInterval(1)),
            store: store,
            sessionID: session.id,
            paneID: pane.id
        )

        #expect(first == .waitingEntered)
        #expect(second == .none)
    }

    @Test("error pane entering waiting announces the combined intent")
    func errorPaneEnteringWaitingAnnouncesCombinedIntent() {
        let pane = TerminalPane(
            title: "agent",
            workingDirectory: "/tmp/a",
            agentKind: .claudeCode,
            agentExecutionState: .error
        )
        let sibling = TerminalPane(title: "sibling", workingDirectory: "/tmp/b")
        let (store, session) = makeSplitStore(paneA: pane, paneB: sibling)

        let intent = intentAfterApplying(
            idlePromptEvent(at: Date()),
            store: store,
            sessionID: session.id,
            paneID: pane.id
        )

        #expect(intent == .errorClearedAndWaiting)
    }
}
