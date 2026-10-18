import AwesoMuxBridgeProtocol
import Foundation
import Testing

@testable import AwesoMuxCore

@MainActor
@Suite("RemoteReconnectState")
struct RemoteReconnectStateTests {
    private let target = RemoteTarget(user: "ed", host: "box.example.com")!

    private func makeStore(
        session: TerminalSession,
        remote: RemoteTarget? = nil
    ) -> SessionStore {
        SessionStore(groups: [
            SessionGroup(name: "group", remote: remote, sessions: [session])
        ])
    }

    private func makeRemoteSession(
        agentKind: AgentKind? = nil,
        agentExecutionState: AgentExecutionState? = nil
    ) -> TerminalSession {
        TerminalSession(
            title: "remote",
            workingDirectory: "~",
            agentKind: agentKind,
            agentExecutionState: agentExecutionState,
            executionPlan: .ssh(SSHExecution(target: target))
        )
    }

    // MARK: - recordPaneProcessError

    // MARK: - confirmPaneRemoteReconnected

    @Test("preserves an output-set error across reconnect, clears a bridge-death one")
    func errorProvenanceGovernsReset() {
        // Output-set error BEFORE the bridge died: the pane was already `.error`,
        // so the latch didn't displace a non-error state — confirm must NOT clear
        // it (INT-697 fix #2).
        let outputError = makeRemoteSession(agentKind: .claudeCode, agentExecutionState: .error)
        let storeA = makeStore(session: outputError, remote: target)
        storeA.recordPaneProcessError(
            in: outputError.id,
            paneID: outputError.activePaneID,
            terminalIsFocused: false
        )
        storeA.confirmPaneRemoteReconnected(
            sessionID: outputError.id,
            paneID: outputError.activePaneID
        )
        #expect(
            storeA.session(id: outputError.id)?
                .layout.pane(id: outputError.activePaneID)?.agentExecutionState == .error
        )

        // Clean pane whose bridge died: the latch DID displace a non-error
        // state, so confirm clears `.error`.
        let cleanPane = makeRemoteSession(agentKind: .claudeCode, agentExecutionState: .running)
        let storeB = makeStore(session: cleanPane, remote: target)
        storeB.recordPaneProcessError(
            in: cleanPane.id,
            paneID: cleanPane.activePaneID,
            terminalIsFocused: false
        )
        storeB.confirmPaneRemoteReconnected(
            sessionID: cleanPane.id,
            paneID: cleanPane.activePaneID
        )
        #expect(
            storeB.session(id: cleanPane.id)?
                .layout.pane(id: cleanPane.activePaneID)?.agentExecutionState != .error
        )
    }

    // MARK: - Legacy heal path (degraded / no status channel)

    @Test("healing a latched remote pane in place clears the overlay and resets error")
    func healClearsLatchedOverlay() {
        // The legacy exit-recovery branch (no status channel) reaches recovery
        // via `healCommandBridgePaneInPlace`, NOT the status `.attached` confirm.
        // Folding the clear into heal is what keeps that path from stranding the
        // "Reconnecting…" overlay over a healthy pane (INT-697 fix #1).
        let session = makeRemoteSession(agentKind: .claudeCode, agentExecutionState: .running)
        let store = makeStore(session: session, remote: target)
        store.recordPaneProcessError(
            in: session.id,
            paneID: session.activePaneID,
            terminalIsFocused: false
        )
        #expect(
            store.session(id: session.id)?.layout.pane(id: session.activePaneID)?.remoteReconnect
                != nil)

        let healed = store.healCommandBridgePaneInPlace(
            sessionID: session.id,
            paneID: session.activePaneID,
            metadata: TerminalBackendMetadata(rawValue: "amx:v1:established")
        )

        #expect(healed != nil)
        let pane = store.session(id: session.id)?.layout.pane(id: session.activePaneID)
        #expect(pane?.remoteReconnect == nil)
        #expect(pane?.agentExecutionState != .error)
    }

    // MARK: - CodingKeys round-trip

    // MARK: - Moved while latched

    @Test("moving to another remote group preserves state and resolves the new live target")
    func movedToAnotherRemoteGroupPreservesStateAndResolvesNewTarget() {
        let otherTarget = RemoteTarget(user: "ed", host: "other.example.com")!
        let session = makeRemoteSession()
        let remoteGroupB = SessionGroup(name: "remote-b", remote: otherTarget, sessions: [])
        let store = SessionStore(groups: [
            SessionGroup(name: "remote-a", remote: target, sessions: [session]),
            remoteGroupB,
        ])
        store.recordPaneProcessError(
            in: session.id,
            paneID: session.activePaneID,
            terminalIsFocused: false
        )

        store.moveSession(id: session.id, toGroupID: remoteGroupB.id, atIndex: 0)

        let pane = store.session(id: session.id)?.layout.pane(id: session.activePaneID)
        // The captured target at latch time survives unchanged...
        #expect(pane?.remoteReconnect == .disconnected(.init(target: target)))
        // Moving groups does not retarget an existing pane; pane identity remains
        // authoritative until an explicit retarget operation exists.
        #expect(store.remoteTarget(forSessionID: session.id) == target)
    }
}
