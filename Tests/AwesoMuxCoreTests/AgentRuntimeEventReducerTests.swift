import Foundation
import Testing
@testable import AwesoMuxCore

@Suite("AgentRuntimeEventReducer")
struct AgentRuntimeEventReducerTests {
    @Test("dedupe and staleness are scoped by pane")
    func dedupeAndStalenessArePaneScoped() throws {
        let firstPane = TerminalPane(title: "a", workingDirectory: "~", agentKind: .shell, executionPlan: .local)
        let secondPane = TerminalPane(title: "b", workingDirectory: "~", agentKind: .shell, executionPlan: .local)
        let session = TerminalSession(
            title: "split",
            workingDirectory: "~",
            layout: .split(
                TerminalSplit(
                    orientation: .vertical,
                    first: .pane(firstPane),
                    second: .pane(secondPane)
                )),
            activePaneID: firstPane.id
        )
        let firstPaneID = firstPane.id
        let secondPaneID = secondPane.id
        let timestamp = Date(timeIntervalSince1970: 10)
        let event = AgentRuntimeEvent(
            source: .claudeCode,
            state: .thinking,
            eventID: "same",
            timestamp: timestamp
        )
        var reducer = AgentRuntimeEventReducer()

        #expect(
            reducer.decision(
                for: event,
                currentSession: session,
                paneID: firstPaneID,
                terminalIsFocused: false,
                now: Date(timeIntervalSince1970: 11)
            ) != nil)
        #expect(
            reducer.decision(
                for: event,
                currentSession: session,
                paneID: firstPaneID,
                terminalIsFocused: false,
                now: Date(timeIntervalSince1970: 11)
            ) == nil)
        #expect(
            reducer.decision(
                for: event,
                currentSession: session,
                paneID: secondPaneID,
                terminalIsFocused: false,
                now: Date(timeIntervalSince1970: 11)
            ) != nil)
    }

    @Test("future timestamps are clamped so later wall-clock events can apply")
    func futureTimestampsAreClamped() throws {
        let session = TerminalSession(title: "shell", workingDirectory: "~", agentKind: .shell)
        let paneID = session.activePaneID
        var reducer = AgentRuntimeEventReducer()
        let now = Date(timeIntervalSince1970: 100)

        _ = reducer.decision(
            for: AgentRuntimeEvent(
                source: .claudeCode,
                state: .thinking,
                eventID: "future",
                timestamp: Date(timeIntervalSince1970: 10_000)
            ),
            currentSession: session,
            paneID: paneID,
            terminalIsFocused: false,
            now: now
        )

        #expect(reducer.stateByPaneID[paneID]?.lastAppliedTimestamp == now)
        #expect(
            reducer.decision(
                for: AgentRuntimeEvent(
                    source: .claudeCode,
                    state: .running,
                    eventID: "later",
                    timestamp: Date(timeIntervalSince1970: 101)
                ),
                currentSession: session,
                paneID: paneID,
                terminalIsFocused: false,
                now: Date(timeIntervalSince1970: 101)
            ) != nil)
    }

    @Test("session start after end accepts an equal timestamp and preserves watermark")
    func equalTimestampSessionStartRestartsEndedLifecycle() throws {
        let session = TerminalSession(title: "claude", workingDirectory: "~", agentKind: .claudeCode)
        let paneID = session.activePaneID
        let timestamp = Date(timeIntervalSince1970: 10)
        var reducer = AgentRuntimeEventReducer()

        #expect(
            reducer.decision(
                for: AgentRuntimeEvent(
                    source: .claudeCode,
                    executionState: .idle,
                    phase: .sessionEnd,
                    timestamp: timestamp
                ),
                currentSession: session,
                paneID: paneID,
                terminalIsFocused: false,
                now: timestamp
            ) != nil)
        #expect(
            reducer.decision(
                for: AgentRuntimeEvent(
                    source: .claudeCode,
                    executionState: .idle,
                    phase: .sessionStart,
                    timestamp: timestamp
                ),
                currentSession: session,
                paneID: paneID,
                terminalIsFocused: false,
                now: timestamp
            ) != nil)
        #expect(reducer.stateByPaneID[paneID]?.lastAppliedTimestamp == timestamp)
        #expect(!reducer.suppressesHeuristicState(for: paneID))
    }

    @Test("session start older than the end watermark cannot revive an ended lifecycle")
    func olderTimestampSessionStartKeepsEndedLifecycle() throws {
        let session = TerminalSession(title: "claude", workingDirectory: "~", agentKind: .claudeCode)
        let paneID = session.activePaneID
        let endTimestamp = Date(timeIntervalSince1970: 10)
        var reducer = AgentRuntimeEventReducer()

        #expect(
            reducer.decision(
                for: AgentRuntimeEvent(
                    source: .claudeCode,
                    executionState: .idle,
                    phase: .sessionEnd,
                    timestamp: endTimestamp
                ),
                currentSession: session,
                paneID: paneID,
                terminalIsFocused: false,
                now: endTimestamp
            ) != nil)
        #expect(
            reducer.decision(
                for: AgentRuntimeEvent(
                    source: .claudeCode,
                    executionState: .idle,
                    phase: .sessionStart,
                    timestamp: Date(timeIntervalSince1970: 5)
                ),
                currentSession: session,
                paneID: paneID,
                terminalIsFocused: false,
                now: endTimestamp
            ) == nil)
        #expect(reducer.stateByPaneID[paneID]?.lastAppliedTimestamp == endTimestamp)
        #expect(reducer.suppressesHeuristicState(for: paneID))
    }

    @Test("a late session end cannot terminate a restarted ended lifecycle")
    func lateSessionEndCannotTerminateRestartedEndedLifecycle() throws {
        let session = TerminalSession(title: "claude", workingDirectory: "~", agentKind: .claudeCode)
        let paneID = session.activePaneID
        var reducer = AgentRuntimeEventReducer()

        let initialEnd = AgentRuntimeEvent(
            source: .claudeCode,
            executionState: .idle,
            phase: .sessionEnd,
            timestamp: Date(timeIntervalSince1970: 10)
        )
        let restart = AgentRuntimeEvent(
            source: .claudeCode,
            executionState: .idle,
            phase: .sessionStart,
            timestamp: Date(timeIntervalSince1970: 20)
        )
        let lateEnd = AgentRuntimeEvent(
            source: .claudeCode,
            executionState: .idle,
            phase: .sessionEnd,
            timestamp: Date(timeIntervalSince1970: 25)
        )
        let currentStop = AgentRuntimeEvent(
            source: .claudeCode,
            executionState: .waiting,
            phase: .stop,
            timestamp: Date(timeIntervalSince1970: 30)
        )
        let currentEnd = AgentRuntimeEvent(
            source: .claudeCode,
            executionState: .idle,
            phase: .sessionEnd,
            timestamp: Date(timeIntervalSince1970: 30)
        )

        #expect(
            reducer.decision(
                for: initialEnd,
                currentSession: session,
                paneID: paneID,
                terminalIsFocused: false,
                now: Date(timeIntervalSince1970: 10)
            ) != nil)
        #expect(
            reducer.decision(
                for: restart,
                currentSession: session,
                paneID: paneID,
                terminalIsFocused: false,
                now: Date(timeIntervalSince1970: 20)
            ) != nil)
        #expect(
            reducer.decision(
                for: lateEnd,
                currentSession: session,
                paneID: paneID,
                terminalIsFocused: false,
                now: Date(timeIntervalSince1970: 20)
            ) == nil)
        #expect(!reducer.suppressesHeuristicState(for: paneID))

        #expect(
            reducer.decision(
                for: currentStop,
                currentSession: session,
                paneID: paneID,
                terminalIsFocused: false,
                now: Date(timeIntervalSince1970: 30)
            ) != nil)
        #expect(
            reducer.decision(
                for: currentEnd,
                currentSession: session,
                paneID: paneID,
                terminalIsFocused: false,
                now: Date(timeIntervalSince1970: 30)
            ) != nil)
        #expect(reducer.suppressesHeuristicState(for: paneID))
    }

    @Test("an attention-only event preserves the pane's prior execution state")
    func attentionOnlyEventPreservesExecutionState() throws {
        var (session, paneID) = singlePaneSession()
        var reducer = AgentRuntimeEventReducer()
        let t10 = Date(timeIntervalSince1970: 10)
        let t20 = Date(timeIntervalSince1970: 20)

        let runningResult = reducer.decision(
            for: AgentRuntimeEvent(
                source: .claudeCode,
                executionState: .running,
                eventID: "e1",
                timestamp: t10
            ),
            currentSession: session, paneID: paneID, terminalIsFocused: false, now: t10
        )
        let runningDecision = try #require(runningResult)
        #expect(runningDecision.update.agentExecutionState == .running)

        _ = WorkspaceAttentionReducer.updatePane(
            &session, paneID: paneID, update: runningDecision.update, now: t10
        )
        #expect(session.layout.pane(id: paneID)?.agentExecutionState == .running)

        let attentionResult = reducer.decision(
            for: AgentRuntimeEvent(
                source: .claudeCode,
                attentionReason: .permissionPrompt,
                eventID: "e2",
                timestamp: t20
            ),
            currentSession: session, paneID: paneID, terminalIsFocused: false, now: t20
        )
        let attentionDecision = try #require(attentionResult)
        #expect(attentionDecision.update.agentExecutionState == nil)
        #expect(attentionDecision.update.attentionReason == .permissionPrompt)

        _ = WorkspaceAttentionReducer.updatePane(
            &session, paneID: paneID, update: attentionDecision.update, now: t20
        )
        #expect(session.layout.pane(id: paneID)?.agentExecutionState == .running)
        #expect(session.layout.pane(id: paneID)?.attentionReason == .permissionPrompt)
    }

    // MARK: - Rename events (routed through the same dedupe/staleness gate)

    private func singlePaneSession() -> (TerminalSession, TerminalPane.ID) {
        let pane = TerminalPane(title: "a", workingDirectory: "~", agentKind: .shell, executionPlan: .local)
        let session = TerminalSession(title: "ws", workingDirectory: "~", layout: .pane(pane))
        return (session, pane.id)
    }

    private func renameEvent(
        title: String?,
        eventID: String? = nil,
        timestamp: Date? = nil
    ) -> AgentRuntimeEvent {
        AgentRuntimeEvent(
            source: .claudeCode,
            phase: .rename,
            eventID: eventID,
            title: title,
            timestamp: timestamp
        )
    }

    @Test("rename resolves to a pane-title action; empty resets; nil drops")
    func renameResolvesToPaneTitleAction() throws {
        let (session, paneID) = singlePaneSession()
        var reducer = AgentRuntimeEventReducer()
        let now = Date(timeIntervalSince1970: 10)

        let renamed = reducer.decision(
            for: renameEvent(title: "Backend"),
            currentSession: session, paneID: paneID, terminalIsFocused: false, now: now
        )
        #expect(renamed?.paneTitleAction == .rename("Backend"))

        let reset = reducer.decision(
            for: renameEvent(title: ""),
            currentSession: session, paneID: paneID, terminalIsFocused: false, now: now
        )
        #expect(reset?.paneTitleAction == .reset)

        // Absent title → malformed → dropped (must not clear a pin).
        let dropped = reducer.decision(
            for: renameEvent(title: nil),
            currentSession: session, paneID: paneID, terminalIsFocused: false, now: now
        )
        #expect(dropped == nil)
    }

    @Test("a rename carrying agent state is dropped (title-only contract)")
    func renameCarryingStateIsDropped() throws {
        let (session, paneID) = singlePaneSession()
        var reducer = AgentRuntimeEventReducer()
        let event = AgentRuntimeEvent(
            source: .claudeCode,
            executionState: .thinking,  // state on a rename event → malformed
            phase: .rename,
            title: "Backend"
        )
        #expect(
            reducer.decision(
                for: event, currentSession: session, paneID: paneID,
                terminalIsFocused: false, now: Date(timeIntervalSince1970: 10)
            ) == nil)
    }

    @Test("a replayed/stale rename is deduped + staleness-dropped like a state event")
    func renameIsDedupedAndStalenessGated() throws {
        let (session, paneID) = singlePaneSession()
        var reducer = AgentRuntimeEventReducer()
        let t10 = Date(timeIntervalSince1970: 10)
        let now = Date(timeIntervalSince1970: 100)

        // First rename applies.
        #expect(
            reducer.decision(
                for: renameEvent(title: "Backend", eventID: "r1", timestamp: t10),
                currentSession: session, paneID: paneID, terminalIsFocused: false, now: now
            )?.paneTitleAction == .rename("Backend"))

        // Exact replay (same eventID + timestamp) is deduped.
        #expect(
            reducer.decision(
                for: renameEvent(title: "Backend", eventID: "r1", timestamp: t10),
                currentSession: session, paneID: paneID, terminalIsFocused: false, now: now
            ) == nil)

        // An OLDER-timestamped rename is staleness-dropped — can't clobber a newer title.
        #expect(
            reducer.decision(
                for: renameEvent(title: "Stale", eventID: "r0", timestamp: Date(timeIntervalSince1970: 5)),
                currentSession: session, paneID: paneID, terminalIsFocused: false, now: now
            ) == nil)
    }

    // MARK: - Open document events

    private func openDocumentEvent(
        path: String? = "/tmp/notes.md",
        eventID: String? = nil,
        timestamp: Date? = nil,
        executionState: AgentExecutionState? = nil,
        attentionReason: AttentionReason? = nil,
        state: AgentState? = nil,
        title: String? = nil
    ) -> AgentRuntimeEvent {
        AgentRuntimeEvent(
            source: .codex,
            executionState: executionState,
            attentionReason: attentionReason,
            state: state,
            phase: .openDocument,
            eventID: eventID,
            title: title,
            documentPath: path,
            timestamp: timestamp
        )
    }

    @Test("open-document resolves to a document-pane action without pane state")
    func openDocumentResolvesToDocumentPaneAction() throws {
        let (session, paneID) = singlePaneSession()
        var reducer = AgentRuntimeEventReducer()

        let result = reducer.decision(
            for: openDocumentEvent(path: "/tmp/notes.markdown"),
            currentSession: session,
            paneID: paneID,
            terminalIsFocused: false,
            now: Date(timeIntervalSince1970: 10)
        )
        let decision = try #require(result)

        #expect(decision.appliesPaneUpdate == false)
        #expect(decision.documentPaneAction == .open(URL(fileURLWithPath: "/tmp/notes.markdown")))
        #expect(decision.update.agentKind == nil)
        #expect(decision.update.agentExecutionState == nil)
        #expect(decision.update.attentionReason == nil)
        #expect(decision.update.agentState == nil)
        #expect(decision.update.unreadNotificationDelta == 0)
    }

    @Test("open-document replay is deduped by eventID and timestamp")
    func openDocumentReplayIsDeduped() {
        let (session, paneID) = singlePaneSession()
        var reducer = AgentRuntimeEventReducer()
        let timestamp = Date(timeIntervalSince1970: 10)
        let event = openDocumentEvent(eventID: "open-1", timestamp: timestamp)

        #expect(
            reducer.decision(
                for: event,
                currentSession: session,
                paneID: paneID,
                terminalIsFocused: false,
                now: Date(timeIntervalSince1970: 11)
            )?.documentPaneAction == .open(URL(fileURLWithPath: "/tmp/notes.md")))
        #expect(
            reducer.decision(
                for: event,
                currentSession: session,
                paneID: paneID,
                terminalIsFocused: false,
                now: Date(timeIntervalSince1970: 11)
            ) == nil)
    }

    @Test("open-document rejects stale timestamps")
    func openDocumentRejectsStaleTimestamp() {
        let (session, paneID) = singlePaneSession()
        var reducer = AgentRuntimeEventReducer()

        _ = reducer.decision(
            for: openDocumentEvent(
                path: "/tmp/fresh.md",
                eventID: "fresh",
                timestamp: Date(timeIntervalSince1970: 10)
            ),
            currentSession: session,
            paneID: paneID,
            terminalIsFocused: false,
            now: Date(timeIntervalSince1970: 11)
        )

        #expect(
            reducer.decision(
                for: openDocumentEvent(
                    path: "/tmp/stale.md",
                    eventID: "stale",
                    timestamp: Date(timeIntervalSince1970: 5)
                ),
                currentSession: session,
                paneID: paneID,
                terminalIsFocused: false,
                now: Date(timeIntervalSince1970: 11)
            ) == nil)
    }

    @Test("malformed open-document events are rejected")
    func malformedOpenDocumentEventsAreRejected() {
        let (session, paneID) = singlePaneSession()
        let events = [
            openDocumentEvent(path: nil),
            openDocumentEvent(path: "notes.md"),
            openDocumentEvent(path: "/tmp/notes.txt"),
            openDocumentEvent(path: "/tmp/notes.md\u{0}suffix"),
            openDocumentEvent(path: "/tmp/notes.md", executionState: .thinking),
            openDocumentEvent(path: "/tmp/notes.md", attentionReason: .permissionPrompt),
            openDocumentEvent(path: "/tmp/notes.md", state: .waiting),
            openDocumentEvent(path: "/tmp/notes.md", title: "not state"),
        ]

        for event in events {
            var reducer = AgentRuntimeEventReducer()
            #expect(
                reducer.decision(
                    for: event,
                    currentSession: session,
                    paneID: paneID,
                    terminalIsFocused: false,
                    now: Date(timeIntervalSince1970: 10)
                ) == nil)
        }
    }
}
