import AwesoMuxBridgeProtocol
import Foundation
import Testing
@testable import AwesoMuxCore

@MainActor
@Suite("Command bridge runtime daemon-death heal")
struct CommandBridgeRuntimeDeathHealTests {
    private let establishedMetadata = TerminalBackendMetadata(rawValue: "amx:v1:established")

    @Test("daemon death in a single-pane workspace reattaches without closing the workspace")
    func singlePaneWorkspaceHealsInPlace() throws {
        let terminalSessionID = try #require(TerminalSessionID(rawValue: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"))
        let pane = TerminalPane(
            terminalSessionID: terminalSessionID,
            terminalBackendMetadata: establishedMetadata,
            title: "shell",
            workingDirectory: "/tmp/single",
            executionPlan: .local
        )
        let session = TerminalSession(
            title: "single",
            workingDirectory: "/tmp/single",
            layout: .pane(pane),
            activePaneID: pane.id
        )
        let store = makeStore(session)

        let recovery = try #require(store.healCommandBridgePaneInPlace(
            sessionID: session.id,
            paneID: pane.id,
            metadata: establishedMetadata
        ))

        let healedSession = try #require(store.session(id: session.id))
        #expect(recovery.paneID == pane.id)
        #expect(recovery.terminalSessionID == terminalSessionID)
        #expect(healedSession.layout == session.layout)
        #expect(healedSession.activePaneID == pane.id)
        #expect(store.groups.first?.sessions.map(\.id) == [session.id])
        #expect(store.selectedSessionID == session.id)
        #expect(store.recentlyClosed.isEmpty)
    }

    @Test("daemon death in a split preserves the dead pane, sibling, geometry, and focus")
    func splitPaneHealsWithoutCollapsing() throws {
        let deadSessionID = try #require(TerminalSessionID(rawValue: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"))
        let siblingSessionID = try #require(TerminalSessionID(rawValue: "cccccccc-cccc-4ccc-8ccc-cccccccccccc"))
        let deadPane = TerminalPane(
            terminalSessionID: deadSessionID,
            terminalBackendMetadata: establishedMetadata,
            title: "dead daemon",
            workingDirectory: "/tmp/dead",
            executionPlan: .local
        )
        let siblingPane = TerminalPane(
            terminalSessionID: siblingSessionID,
            terminalBackendMetadata: establishedMetadata,
            title: "sibling",
            workingDirectory: "/tmp/sibling",
            executionPlan: .local
        )
        let layout = TerminalPaneLayout.split(TerminalSplit(
            orientation: .vertical,
            first: .pane(deadPane),
            second: .pane(siblingPane),
            firstFraction: 0.37
        ))
        let session = TerminalSession(
            title: "split",
            workingDirectory: "/tmp/dead",
            layout: layout,
            activePaneID: deadPane.id
        )
        let store = makeStore(session)

        let recovery = try #require(store.healCommandBridgePaneInPlace(
            sessionID: session.id,
            paneID: deadPane.id,
            metadata: establishedMetadata
        ))

        let healedSession = try #require(store.session(id: session.id))
        #expect(recovery.paneID == deadPane.id)
        #expect(recovery.terminalSessionID == deadSessionID)
        #expect(healedSession.layout == layout)
        #expect(healedSession.layout.pane(id: deadPane.id) == deadPane)
        #expect(healedSession.layout.pane(id: siblingPane.id) == siblingPane)
        #expect(healedSession.layout.paneCount == 2)
        #expect(healedSession.activePaneID == deadPane.id)

        guard case let .split(split) = healedSession.layout else {
            Issue.record("healed layout should remain a split")
            return
        }
        #expect(split.orientation == .vertical)
        #expect(split.firstFraction == 0.37)
    }

    @Test("daemon death in an agent pane reattaches the same pane session")
    func agentPaneHealsToWorkingPane() throws {
        let terminalSessionID = try #require(TerminalSessionID(rawValue: "dddddddd-dddd-4ddd-8ddd-dddddddddddd"))
        let agentPane = TerminalPane(
            terminalSessionID: terminalSessionID,
            terminalBackendMetadata: establishedMetadata,
            title: "codex",
            workingDirectory: "/tmp/agent",
            agentKind: .codex,
            agentExecutionState: .thinking,
            executionPlan: .local
        )
        let session = TerminalSession(
            title: "agent",
            workingDirectory: "/tmp/agent",
            layout: .pane(agentPane),
            activePaneID: agentPane.id
        )
        let store = makeStore(session)

        let recovery = try #require(store.healCommandBridgePaneInPlace(
            sessionID: session.id,
            paneID: agentPane.id,
            metadata: establishedMetadata
        ))

        let healedPane = try #require(store.session(id: session.id)?.layout.pane(id: agentPane.id))
        #expect(recovery.paneID == agentPane.id)
        #expect(recovery.terminalSessionID == terminalSessionID)
        #expect(healedPane.terminalSessionID == terminalSessionID)
        #expect(healedPane.terminalBackendMetadata == establishedMetadata)
        #expect(store.session(id: session.id)?.layout.paneCount == 1)
        #expect(store.selectedSessionID == session.id)
    }

    private func makeStore(_ session: TerminalSession) -> SessionStore {
        SessionStore(
            groups: [SessionGroup(name: "awesoMux", sessions: [session])],
            selectedSessionID: session.id
        )
    }
}
