import Foundation
import Testing
@testable import AwesoMuxCore

@MainActor
@Suite("RemoteReconnectState")
struct RemoteReconnectStateTests {
    private let target = RemoteTarget(user: "ed", host: "box.example.com")

    private func makeStore(
        session: TerminalSession,
        remote: RemoteTarget? = nil
    ) -> SessionStore {
        SessionStore(groups: [
            SessionGroup(name: "group", remote: remote, sessions: [session])
        ])
    }

    // MARK: - recordPaneProcessError

    @Test("latches disconnected for a remote-group pane")
    func latchesDisconnectedForRemoteGroup() {
        let session = TerminalSession(title: "remote", workingDirectory: "~")
        let store = makeStore(session: session, remote: target)

        let recorded = store.recordPaneProcessError(
            in: session.id,
            paneID: session.activePaneID,
            terminalIsFocused: false
        )

        #expect(recorded)
        let pane = store.session(id: session.id)?.layout.pane(id: session.activePaneID)
        #expect(pane?.remoteReconnect == .disconnected(.init(target: target)))
    }

    @Test("leaves reconnect state nil for a local group")
    func leavesNilForLocalGroup() {
        let session = TerminalSession(title: "local", workingDirectory: "~")
        let store = makeStore(session: session, remote: nil)

        let recorded = store.recordPaneProcessError(
            in: session.id,
            paneID: session.activePaneID,
            terminalIsFocused: false
        )

        #expect(recorded)
        let pane = store.session(id: session.id)?.layout.pane(id: session.activePaneID)
        #expect(pane?.remoteReconnect == nil)
    }

    // MARK: - confirmPaneRemoteReconnected

    @Test("clears state and resets a bridge-death error execution state")
    func clearsStateAndResetsErrorState() {
        let session = TerminalSession(
            title: "remote",
            workingDirectory: "~",
            agentKind: .claudeCode,
            agentExecutionState: .running
        )
        let store = makeStore(session: session, remote: target)
        store.recordPaneProcessError(
            in: session.id,
            paneID: session.activePaneID,
            terminalIsFocused: false
        )
        // Sanity: the bridge death actually latched .error + .disconnected
        // before we assert the confirm path clears both.
        #expect(store.session(id: session.id)?.layout.pane(id: session.activePaneID)?.agentExecutionState == .error)

        let confirmed = store.confirmPaneRemoteReconnected(
            sessionID: session.id,
            paneID: session.activePaneID
        )

        #expect(confirmed)
        let pane = store.session(id: session.id)?.layout.pane(id: session.activePaneID)
        #expect(pane?.remoteReconnect == nil)
        // claudeCode's kind-appropriate idle state is `.running`, not a
        // hardcoded shell `.idle` — proves this isn't cloning
        // resetPaneAgentChromeToShell's full chrome reset.
        #expect(pane?.agentExecutionState == .running)
        #expect(pane?.agentKind == .claudeCode)
    }

    @Test("preserves an output-set error across reconnect, clears a bridge-death one")
    func errorProvenanceGovernsReset() {
        // Output-set error BEFORE the bridge died: the pane was already `.error`,
        // so the latch didn't displace a non-error state — confirm must NOT clear
        // it (INT-697 fix #2).
        let outputError = TerminalSession(
            title: "remote",
            workingDirectory: "~",
            agentKind: .claudeCode,
            agentExecutionState: .error
        )
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
        let cleanPane = TerminalSession(
            title: "remote",
            workingDirectory: "~",
            agentKind: .claudeCode,
            agentExecutionState: .running
        )
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
        let session = TerminalSession(
            title: "remote",
            workingDirectory: "~",
            agentKind: .claudeCode,
            agentExecutionState: .running
        )
        let store = makeStore(session: session, remote: target)
        store.recordPaneProcessError(
            in: session.id,
            paneID: session.activePaneID,
            terminalIsFocused: false
        )
        #expect(store.session(id: session.id)?.layout.pane(id: session.activePaneID)?.remoteReconnect != nil)

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

    @Test("no-ops and returns false when nothing was latched")
    func noOpsWhenNothingLatched() {
        let session = TerminalSession(title: "remote", workingDirectory: "~")
        let store = makeStore(session: session, remote: target)

        let confirmed = store.confirmPaneRemoteReconnected(
            sessionID: session.id,
            paneID: session.activePaneID
        )

        #expect(!confirmed)
        let pane = store.session(id: session.id)?.layout.pane(id: session.activePaneID)
        #expect(pane?.remoteReconnect == nil)
        #expect(pane?.agentExecutionState == .idle)
    }

    // MARK: - CodingKeys round-trip

    @Test("remoteReconnect is excluded from Codable")
    func excludedFromCodable() throws {
        var pane = TerminalPane(title: "remote", workingDirectory: "~")
        pane.remoteReconnect = .disconnected(.init(target: target))

        let data = try JSONEncoder().encode(pane)
        let decoded = try JSONDecoder().decode(TerminalPane.self, from: data)

        #expect(decoded.remoteReconnect == nil)
    }

    // MARK: - Moved while latched

    @Test("moving to a local group preserves latched state and captured target")
    func movedToLocalGroupPreservesState() {
        let session = TerminalSession(title: "remote", workingDirectory: "~")
        let localGroup = SessionGroup(name: "local", sessions: [])
        let store = SessionStore(groups: [
            SessionGroup(name: "remote-a", remote: target, sessions: [session]),
            localGroup
        ])
        store.recordPaneProcessError(
            in: session.id,
            paneID: session.activePaneID,
            terminalIsFocused: false
        )

        store.moveSession(id: session.id, toGroupID: localGroup.id, atIndex: 0)

        let pane = store.session(id: session.id)?.layout.pane(id: session.activePaneID)
        #expect(pane?.remoteReconnect == .disconnected(.init(target: target)))
        #expect(store.remoteTarget(forSessionID: session.id) == nil)
    }

    @Test("moving to another remote group preserves state and resolves the new live target")
    func movedToAnotherRemoteGroupPreservesStateAndResolvesNewTarget() {
        let otherTarget = RemoteTarget(user: "ed", host: "other.example.com")
        let session = TerminalSession(title: "remote", workingDirectory: "~")
        let remoteGroupB = SessionGroup(name: "remote-b", remote: otherTarget, sessions: [])
        let store = SessionStore(groups: [
            SessionGroup(name: "remote-a", remote: target, sessions: [session]),
            remoteGroupB
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
        // ...even though the LIVE group target now resolves to B (the overlay
        // uses this for its button label per the plan's live-target-wins rule).
        #expect(store.remoteTarget(forSessionID: session.id) == otherTarget)
    }
}
