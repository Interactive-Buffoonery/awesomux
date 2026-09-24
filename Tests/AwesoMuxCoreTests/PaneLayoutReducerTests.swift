import AwesoMuxBridgeProtocol
import Foundation
import Testing
@testable import AwesoMuxCore

@Suite("PaneLayoutReducer")
struct PaneLayoutReducerTests {

    @Test("splitting a done pane resets it so the rollup follows the fresh shell")
    func splitResetsStaleDonePane() throws {
        let now = Date(timeIntervalSince1970: 100)
        let active = TerminalPane(
            title: "agent",
            workingDirectory: "~",
            agentKind: .codex,
            agentExecutionState: .done,
            executionPlan: .local
        )
        let session = TerminalSession(
            title: "ws",
            workingDirectory: "~",
            layout: .pane(active),
            activePaneID: active.id
        )

        let result = try #require(
            PaneLayoutReducer.splitActivePane(
                in: session,
                orientation: .vertical,
                now: now
            ))

        // S1: the just-finished agent's `.done` outranks `.idle`, so without the
        // reset the workspace row stays "Done" after focus moves to the fresh
        // shell. Reset the split-off pane and the rollup follows the new shell.
        #expect(result.session.layout.pane(id: active.id)?.agentExecutionState == .idle)
        #expect(result.session.agentRollup(at: now).state == .idle)
        // Determinism (review auto-fix): the minted pane carries the reducer's
        // `now`, not an implicit `Date()`.
        #expect(
            result.session.layout.pane(id: result.newPaneID)?.lastAgentStateChangeAt == now
        )
    }

    @Test("pwd updates clear sticky remote host while local-looking titles do not")
    func paneUpdatePreservesRemoteStickinessUntilPwd() throws {
        let pane = TerminalPane(title: "alice@remote", workingDirectory: "~", executionPlan: .local)
        var session = TerminalSession(
            title: "alice@remote",
            workingDirectory: "~",
            agentKind: .shell,
            layout: .pane(pane),
            activePaneID: pane.id
        )

        session = try #require(
            PaneLayoutReducer.updatePane(
                in: session,
                paneID: pane.id,
                title: "alice@remote",
                workingDirectory: nil,
                localHostnames: ["local"]
            ))
        #expect(session.activePane?.remoteHost == "remote")

        session = try #require(
            PaneLayoutReducer.updatePane(
                in: session,
                paneID: pane.id,
                title: "local title",
                workingDirectory: nil,
                localHostnames: ["local"]
            ))
        #expect(session.activePane?.remoteHost == "remote")

        session = try #require(
            PaneLayoutReducer.updatePane(
                in: session,
                paneID: pane.id,
                title: nil,
                workingDirectory: NSHomeDirectory(),
                localHostnames: ["local"]
            ))
        #expect(session.activePane?.remoteHost == nil)
    }

    @Test("a nested ssh command does not replace the retained target")
    func nestedSSHDoesNotReplaceRetainedTarget() throws {
        let pane = TerminalPane(
            title: "alice@host-a",
            workingDirectory: "~",
            remoteHost: "host-a",
            remoteSSHTarget: "host-a",
            executionPlan: .local
        )
        var session = TerminalSession(
            title: "alice@host-a",
            workingDirectory: "~",
            layout: .pane(pane),
            activePaneID: pane.id
        )

        #expect(
            PaneLayoutReducer.noteSubmittedCommand(
                in: session,
                paneID: pane.id,
                command: "ssh host-b"
            ) == nil
        )

        session = try #require(
            PaneLayoutReducer.updatePane(
                in: session,
                paneID: pane.id,
                title: "alice@host-a: ~",
                workingDirectory: nil,
                localHostnames: ["local"]
            ))
        #expect(session.activePane?.remoteSSHTarget == "host-a")
        #expect(session.activePane?.pendingRemoteSSHTarget == nil)
    }

    @Test("an unrecognized ssh command does not republish an unchanged pane")
    func unrecognizedSSHCommandDoesNotRepublishUnchangedPane() {
        let pane = TerminalPane(title: "shell", workingDirectory: "~", executionPlan: .local)
        let session = TerminalSession(
            title: "shell",
            workingDirectory: "~",
            layout: .pane(pane),
            activePaneID: pane.id
        )

        #expect(
            PaneLayoutReducer.noteSubmittedCommand(
                in: session,
                paneID: pane.id,
                command: "ssh -p 2222 devbox",
                submittedFromLocalShell: true
            ) == nil
        )
    }
}
