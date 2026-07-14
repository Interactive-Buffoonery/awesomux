import Foundation
import Testing
@testable import AwesoMuxCore

@Suite("PaneLayoutReducer")
struct PaneLayoutReducerTests {
    @Test("recycle replaces only the active pane and clears transient session state")
    func recycleReplacesActivePaneAndClearsState() throws {
        let firstPane = TerminalPane(title: "one", workingDirectory: "/one", executionPlan: .local)
        let secondPane = TerminalPane(title: "two", workingDirectory: "/two", executionPlan: .local)
        let layout = TerminalPaneLayout.split(
            TerminalSplit(
                orientation: .vertical,
                first: .pane(firstPane),
                second: .pane(secondPane)
            ))
        let session = TerminalSession(
            title: "workspace",
            workingDirectory: "/two",
            agentKind: .shell,
            agentState: .done,
            needsTerminalQuitConfirmation: true,
            shellActivity: .busy,
            unreadNotificationCount: 4,
            layout: layout,
            activePaneID: secondPane.id
        )

        let result = try #require(
            PaneLayoutReducer.recycleActivePane(
                in: session,
                now: Date(timeIntervalSince1970: 1)
            ))

        #expect(result.discardedPaneID == secondPane.id)
        #expect(result.session.layout.pane(id: firstPane.id) == firstPane)
        #expect(result.session.activePaneID != secondPane.id)
        #expect(result.session.unreadNotificationCount == 0)
        #expect(result.session.needsTerminalQuitConfirmation == false)
        #expect(result.session.shellActivity == .idle)
        #expect(result.session.agentState == .idle)
    }

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

    @Test("splitting a running pane preserves its live state")
    func splitPreservesLiveRunningPane() throws {
        let now = Date(timeIntervalSince1970: 100)
        let active = TerminalPane(
            title: "agent",
            workingDirectory: "~",
            agentKind: .codex,
            agentExecutionState: .running,
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

        // Only a stale terminal `.done` is reset — a live `.running` agent must
        // keep its state (and quit-risk freshness).
        #expect(result.session.layout.pane(id: active.id)?.agentExecutionState == .running)
    }

    @Test("recycle mints the fresh pane with the reducer's now")
    func recycleThreadsNowIntoMintedPane() throws {
        let now = Date(timeIntervalSince1970: 250)
        let active = TerminalPane(title: "shell", workingDirectory: "~", agentKind: .shell, executionPlan: .local)
        let session = TerminalSession(
            title: "ws",
            workingDirectory: "~",
            layout: .pane(active),
            activePaneID: active.id
        )

        let result = try #require(PaneLayoutReducer.recycleActivePane(in: session, now: now))

        let minted = result.session.layout.pane(id: result.session.activePaneID)
        #expect(minted?.lastAgentStateChangeAt == now)
    }

    @Test("recycle preserves the active pane's color on the recycled pane")
    func recyclePreservesPaneColor() throws {
        let now = Date(timeIntervalSince1970: 300)
        var active = TerminalPane(title: "shell", workingDirectory: "~", agentKind: .shell, executionPlan: .local)
        active.color = .palette(.teal)
        let session = TerminalSession(
            title: "ws",
            workingDirectory: "~",
            layout: .pane(active),
            activePaneID: active.id
        )

        let result = try #require(PaneLayoutReducer.recycleActivePane(in: session, now: now))

        let recycled = result.session.layout.pane(id: result.session.activePaneID)
        #expect(recycled?.color == .palette(.teal))
    }

    @Test("split and recycle preserve the active pane execution plan")
    func paneCreationPreservesExecutionPlan() throws {
        let target = RemoteTarget(user: "alice", host: "buildbox")!
        let plan = PaneExecutionPlan.ssh(SSHExecution(target: target))
        let pane = TerminalPane(
            title: "remote",
            workingDirectory: "/srv/app",
            executionPlan: plan
        )
        let session = TerminalSession(
            title: "remote",
            workingDirectory: "/srv/app",
            layout: .pane(pane),
            activePaneID: pane.id
        )

        let split = try #require(
            PaneLayoutReducer.splitActivePane(
                in: session,
                orientation: .vertical,
                now: .now
            ))
        #expect(split.session.activePane?.executionPlan == plan)

        let recycled = try #require(
            PaneLayoutReducer.recycleActivePane(
                in: split.session,
                now: .now
            ))
        #expect(recycled.session.activePane?.executionPlan == plan)
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

    // MARK: - resetPaneAgentChromeToShell

    @Test("resetPaneAgentChromeToShell clears agent identity to shell defaults")
    func resetPaneAgentChromeToShellClearsAgentIdentity() throws {
        var pane = TerminalPane(
            title: "claude",
            workingDirectory: "/work",
            agentKind: .claudeCode,
            agentExecutionState: .waiting,
            attentionReason: .userInputRequired,
            executionPlan: .local
        )
        // INT-609: progressReport is pane-scoped store state, not surface-scoped —
        // a fresh daemon incarnation must clear it or a stale progress bar from
        // the old surface renders on the new one's first frame.
        pane.progressReport = TerminalProgressReport(state: .set, progress: 42)
        let session = TerminalSession(
            title: "ws",
            workingDirectory: "/work",
            layout: .pane(pane),
            activePaneID: pane.id
        )

        let updated = try #require(
            PaneLayoutReducer.resetPaneAgentChromeToShell(
                in: session,
                paneID: pane.id
            ))
        let resetPane = try #require(updated.layout.pane(id: pane.id))

        #expect(resetPane.agentKind == .shell)
        #expect(resetPane.agentExecutionState == AgentKind.shell.initialSessionState.executionState ?? .idle)
        #expect(resetPane.attentionReason == nil)
        #expect(resetPane.progressReport == nil)
    }

    @Test("resetPaneAgentChromeToShell preserves non-agent pane fields")
    func resetPaneAgentChromeToShellPreservesNonAgentFields() throws {
        let pane = TerminalPane(
            id: UUID(),
            terminalSessionID: .generate(),
            title: "my title",
            isTitleUserEdited: true,
            workingDirectory: "/some/path",
            color: .palette(.teal),
            agentKind: .codex,
            agentExecutionState: .running,
            attentionReason: .userInputRequired,
            executionPlan: .local
        )
        let session = TerminalSession(
            title: "ws",
            workingDirectory: "/some/path",
            layout: .pane(pane),
            activePaneID: pane.id
        )

        let updated = try #require(
            PaneLayoutReducer.resetPaneAgentChromeToShell(
                in: session,
                paneID: pane.id
            ))
        let resetPane = try #require(updated.layout.pane(id: pane.id))

        // Agent identity cleared
        #expect(resetPane.agentKind == .shell)
        #expect(resetPane.attentionReason == nil)
        // Non-agent fields preserved
        #expect(resetPane.id == pane.id)
        #expect(resetPane.terminalSessionID == pane.terminalSessionID)
        #expect(resetPane.title == pane.title)
        #expect(resetPane.isTitleUserEdited == pane.isTitleUserEdited)
        #expect(resetPane.workingDirectory == pane.workingDirectory)
        #expect(resetPane.color == pane.color)
    }

    @Test("resetPaneAgentChromeToShell returns nil for unknown pane ID")
    func resetPaneAgentChromeToShellReturnsNilForUnknownPane() {
        let pane = TerminalPane(title: "shell", workingDirectory: "/", executionPlan: .local)
        let session = TerminalSession(
            title: "ws",
            workingDirectory: "/",
            layout: .pane(pane),
            activePaneID: pane.id
        )

        let result = PaneLayoutReducer.resetPaneAgentChromeToShell(
            in: session,
            paneID: UUID()
        )
        #expect(result == nil)
    }

    @Test("reset pane effective chrome state reflects shell-idle after reset")
    func resetPaneEffectiveChromeStateReflectsShellIdle() throws {
        let pane = TerminalPane(
            title: "claude",
            workingDirectory: "/work",
            agentKind: .claudeCode,
            agentExecutionState: .waiting,
            attentionReason: .userInputRequired,
            executionPlan: .local
        )
        let session = TerminalSession(
            title: "ws",
            workingDirectory: "/work",
            layout: .pane(pane),
            activePaneID: pane.id
        )

        let updated = try #require(
            PaneLayoutReducer.resetPaneAgentChromeToShell(
                in: session,
                paneID: pane.id
            ))
        let resetPane = try #require(updated.layout.pane(id: pane.id))

        // A shell pane with no attentionReason and idle execution state should
        // display shell-idle — not the stale agent identity.
        let chrome = resetPane.effectiveChromeState
        #expect(chrome == AgentState.idle)
    }
}
