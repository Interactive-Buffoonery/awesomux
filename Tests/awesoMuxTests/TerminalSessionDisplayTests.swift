import AwesoMuxCore
import Foundation
import Testing
@testable import awesoMux

@Suite("TerminalSession display (INT-333)")
struct TerminalSessionDisplayTests {
    @Test("peek refresh key changes on a shell idle↔busy flip that session equality misses")
    func peekRefreshKeyCatchesShellActivityFlip() {
        let sessionID = UUID()
        let idlePane = TerminalPane(
            title: "sh", workingDirectory: "~", agentKind: .shell, shellActivity: .idle,
            executionPlan: .local
        )
        let busyPane = TerminalPane(
            id: idlePane.id, title: "sh", workingDirectory: "~", agentKind: .shell,
            shellActivity: .busy,
            executionPlan: .local
        )
        let idleSession = TerminalSession(
            id: sessionID, title: "ws", workingDirectory: "~",
            layout: .pane(idlePane), activePaneID: idlePane.id
        )
        let busySession = TerminalSession(
            id: sessionID, title: "ws", workingDirectory: "~",
            layout: .pane(busyPane), activePaneID: busyPane.id
        )

        // S4: `==` deliberately excludes `shellActivity`, so `onChange(of: session)`
        // would never see the flip…
        #expect(idleSession == busySession)
        // …but the peek refresh key folds the rollup's chrome state, so a live
        // peek refreshes when the shell goes busy.
        #expect(idleSession.peekRefreshKey != busySession.peekRefreshKey)
    }

    @Test("local sidebar location uses abbreviated active pane cwd")
    func localSidebarLocationUsesAbbreviatedActivePaneCWD() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let pane = TerminalPane(
            title: "shell",
            workingDirectory: "\(home)/Developer/awesomux",
            executionPlan: .local
        )
        let session = TerminalSession(
            title: "shell",
            workingDirectory: "/tmp/stale",
            agentKind: .shell,
            layout: .pane(pane),
            activePaneID: pane.id
        )

        #expect(session.sidebarLocation.kind == SidebarSessionLocation.Kind.local)
        #expect(session.sidebarLocation.displayText == "~/Developer/awesomux")
        #expect(session.sidebarLocation.searchText == "~/Developer/awesomux")
        #expect(session.sidebarLocation.identityText == "local:~/Developer/awesomux")
        #expect(session.sidebarLocation.accessibilityLabel == "~/Developer/awesomux")
    }

    @Test("remote sidebar location uses active pane host")
    func remoteSidebarLocationUsesActivePaneHost() {
        let pane = TerminalPane(
            title: "alice@devbox: ~/work",
            workingDirectory: "/Users/example/local-before-ssh",
            remoteHost: "devbox",
            executionPlan: .local
        )
        let session = TerminalSession(
            title: "shell",
            workingDirectory: "/Users/example/local-before-ssh",
            agentKind: .shell,
            layout: .pane(pane),
            activePaneID: pane.id
        )

        #expect(session.sidebarLocation.kind == SidebarSessionLocation.Kind.remote)
        #expect(session.sidebarLocation.displayText == "devbox")
        #expect(session.sidebarLocation.searchText == "devbox")
        #expect(session.sidebarLocation.identityText == "remote:devbox")
        #expect(session.sidebarLocation.accessibilityLabel == "Remote session on devbox")
    }

    @Test("inactive remote pane does not override local active pane")
    func inactiveRemotePaneDoesNotOverrideLocalActivePane() {
        let localPane = TerminalPane(title: "local", workingDirectory: "/tmp/local", executionPlan: .local)
        let remotePane = TerminalPane(
            title: "alice@devbox: ~/work",
            workingDirectory: "/tmp/stale",
            remoteHost: "devbox",
            executionPlan: .local
        )
        let layout = TerminalPaneLayout.split(
            TerminalSplit(
                orientation: .vertical,
                first: .pane(localPane),
                second: .pane(remotePane)
            )
        )
        let session = TerminalSession(
            title: "shell",
            workingDirectory: "/tmp/stale",
            agentKind: .shell,
            layout: layout,
            activePaneID: localPane.id
        )

        #expect(session.sidebarLocation.kind == SidebarSessionLocation.Kind.local)
        #expect(session.sidebarLocation.displayText == "/tmp/local")
    }

    @Test("remote and local matching display strings have different identities")
    func remoteAndLocalMatchingDisplayStringsHaveDifferentIdentities() {
        let remotePane = TerminalPane(
            title: "ssh",
            workingDirectory: "/tmp/local",
            remoteHost: "devbox",
            executionPlan: .local
        )
        let remote = TerminalSession(
            title: "shell",
            workingDirectory: "/tmp/local",
            agentKind: .shell,
            layout: .pane(remotePane),
            activePaneID: remotePane.id
        )
        let local = TerminalSession(
            title: "shell",
            workingDirectory: "devbox",
            agentKind: .shell
        )

        #expect(remote.sidebarLocation.displayText == local.sidebarLocation.displayText)
        #expect(remote.sidebarLocation.identityText != local.sidebarLocation.identityText)
    }

    @Test("shell chrome state follows effective shell activity")
    func shellChromeStateFollowsEffectiveShellActivity() {
        let idleShell = TerminalSession(
            title: "shell",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .running,
            shellActivity: .idle
        )
        let busyShell = TerminalSession(
            title: "shell",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .idle,
            shellActivity: .busy
        )

        #expect(idleShell.chromeAwState.label == "Idle")
        #expect(busyShell.chromeAwState.label == "Running")
    }

    @Test("agent chrome state still follows agent state")
    func agentChromeStateStillFollowsAgentState() {
        let waitingAgent = TerminalSession(
            title: "codex",
            workingDirectory: "~",
            agentKind: .codex,
            agentState: .waiting,
            shellActivity: .busy
        )

        #expect(waitingAgent.chromeAwState.label == "Waiting")
    }

    @Test("chrome state reflects the loudest pane in a split (INT-504)")
    func chromeStateReflectsLoudestPane() {
        // Active pane is an idle shell; the sibling Codex pane needs input.
        let shell = TerminalPane(title: "shell", workingDirectory: "~", agentKind: .shell, executionPlan: .local)
        let codex = TerminalPane(
            title: "codex", workingDirectory: "~", agentKind: .codex,
            attentionReason: .permissionPrompt,
            executionPlan: .local
        )
        let split = TerminalSession(
            title: "split",
            workingDirectory: "~",
            layout: .split(TerminalSplit(
                orientation: .vertical,
                first: .pane(shell),
                second: .pane(codex)
            )),
            activePaneID: shell.id
        )

        #expect(split.chromeAwState == .needs)
        #expect(split.chromeAwState.label == "Needs input")
    }
}

@Suite("Pane focus accent state (INT-721)")
struct FocusAccentAwStateTests {
    /// The INT-506 divergence the fix targets: a dead pane keeping a low-priority
    /// attention reason reads as its recovery hint (not `.needsAttention`), so the
    /// execution rollup leaves `.needs` while `needsAcknowledgement` (and the
    /// banner) stay up. The focus rail must follow the banner, not the rollup.
    @Test("focus accent stays needs while acknowledgement pends but rollup left needs")
    func focusAccentFollowsAcknowledgementLedgerNotRollup() {
        let deadWithBell = TerminalPane(
            title: "codex", workingDirectory: "~", agentKind: .codex,
            agentExecutionState: .done, attentionReason: .bell,
            executionPlan: .local
        )
        let session = TerminalSession(
            title: "codex", workingDirectory: "~",
            layout: .pane(deadWithBell), activePaneID: deadWithBell.id
        )

        // Pin the divergence: banner up, rollup off `.needs`…
        #expect(session.needsAcknowledgement)
        #expect(session.chromeAwState != .needs)
        // …but the focus rail stays peach so it agrees with the banner above it.
        #expect(session.focusAccentAwState == .needs)
    }

    @Test("focus accent equals the rollup when nothing needs acknowledgement")
    func focusAccentEqualsRollupWithoutAcknowledgement() {
        let idle = TerminalSession(
            title: "shell", workingDirectory: "~", agentKind: .shell,
            agentState: .idle, shellActivity: .idle
        )

        #expect(!idle.needsAcknowledgement)
        #expect(idle.focusAccentAwState == idle.chromeAwState)
        #expect(idle.focusAccentAwState != .needs)
    }

    @Test("a live needs pane already resolves to needs on both planes")
    func focusAccentMatchesLiveNeeds() {
        let prompting = TerminalPane(
            title: "codex", workingDirectory: "~", agentKind: .codex,
            attentionReason: .permissionPrompt,
            executionPlan: .local
        )
        let session = TerminalSession(
            title: "codex", workingDirectory: "~",
            layout: .pane(prompting), activePaneID: prompting.id
        )

        #expect(session.chromeAwState == .needs)
        #expect(session.focusAccentAwState == .needs)
    }

    /// Session-vs-pane scoping trap: `needsAcknowledgement` is session-scoped, the
    /// stripe is the active pane's. A needy background sibling holds the banner up,
    /// so the active (idle) pane's rail follows it — matching the session-scoped
    /// banner, even though the active pane itself isn't needy.
    @Test("focus accent follows a needy background sibling in a split")
    func focusAccentFollowsNeedySiblingInSplit() {
        let idleActive = TerminalPane(
            title: "shell", workingDirectory: "~", agentKind: .shell,
            shellActivity: .idle,
            executionPlan: .local
        )
        let deadWithBell = TerminalPane(
            title: "codex", workingDirectory: "~", agentKind: .codex,
            agentExecutionState: .done, attentionReason: .bell,
            executionPlan: .local
        )
        let split = TerminalSession(
            title: "split", workingDirectory: "~",
            layout: .split(TerminalSplit(
                orientation: .horizontal,
                first: .pane(idleActive),
                second: .pane(deadWithBell)
            )),
            activePaneID: idleActive.id
        )

        #expect(split.needsAcknowledgement)
        #expect(split.chromeAwState != .needs)
        #expect(split.focusAccentAwState == .needs)
    }
}
