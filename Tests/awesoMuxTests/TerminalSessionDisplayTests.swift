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

    @Test("declared SSH target wins over observed sidebar host")
    func declaredSSHTargetWinsOverObservedSidebarHost() {
        let target = RemoteTarget(user: "alice", host: "buildbox-alias")!
        let pane = TerminalPane(
            title: "deploy@resolved.example: ~/work",
            workingDirectory: "/Users/example/local-before-ssh",
            remoteHost: "resolved.example",
            executionPlan: .ssh(SSHExecution(target: target))
        )
        let session = TerminalSession(
            title: "shell",
            workingDirectory: "/Users/example/local-before-ssh",
            layout: .pane(pane),
            activePaneID: pane.id
        )

        #expect(session.sidebarLocation.displayText == "alice@buildbox-alias")
        #expect(session.sidebarLocation.identityText == "remote:alice@buildbox-alias")
        #expect(
            session.sidebarLocation.accessibilityLabel
                == "Remote session on alice@buildbox-alias"
        )
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
            layout: .split(
                TerminalSplit(
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

@Suite("Pane focus accent state (pane-scoped; supersedes INT-721)")
struct FocusAccentAwStateTests {
    /// The INT-506 divergence the fold targets: a dead pane keeping a low-priority
    /// attention reason reads as its recovery hint (not `.needsAttention`), so the
    /// execution state leaves `.needs` while `needsAcknowledgement` (and the
    /// banner) stay up. The pane's rail must follow the ledger, not the rollup.
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
        // …but the pane's rail stays peach so it agrees with the banner above it.
        #expect(session.focusAccentAwState(for: deadWithBell) == .needs)
    }

    @Test("focus accent equals the pane's chrome state without acknowledgement")
    func focusAccentEqualsPaneChromeStateWithoutAcknowledgement() {
        let idle = TerminalPane(
            title: "shell", workingDirectory: "~", agentKind: .shell,
            shellActivity: .idle,
            executionPlan: .local
        )
        let session = TerminalSession(
            title: "shell", workingDirectory: "~",
            layout: .pane(idle), activePaneID: idle.id
        )

        #expect(!session.needsAcknowledgement)
        #expect(session.focusAccentAwState(for: idle) == idle.effectiveChromeState.awState)
        #expect(session.focusAccentAwState(for: idle) != .needs)
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
        #expect(session.focusAccentAwState(for: prompting) == .needs)
    }

    /// The scoping fix that superseded INT-721's session fold: a needy background
    /// sibling used to turn the *focused* pane's rail peach, so the rail couldn't
    /// identify which pane wanted input. Now the peach rail belongs to the needy
    /// pane and the focused idle pane keeps its normal accent.
    @Test("focus accent stays on the needy pane, not its focused sibling")
    func focusAccentStaysOnNeedyPaneNotFocusedSibling() {
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
            layout: .split(
                TerminalSplit(
                    orientation: .horizontal,
                    first: .pane(idleActive),
                    second: .pane(deadWithBell)
                )),
            activePaneID: idleActive.id
        )

        // Banner still session-scoped…
        #expect(split.needsAcknowledgement)
        // …but only the needy pane's rail goes peach.
        #expect(split.focusAccentAwState(for: idleActive) != .needs)
        #expect(split.focusAccentAwState(for: deadWithBell) == .needs)
        // ID-keyed lookup (the split divider's path) agrees with the direct one.
        #expect(split.focusAccentAwState(forPaneID: idleActive.id) != .needs)
        #expect(split.focusAccentAwState(forPaneID: deadWithBell.id) == .needs)
    }

    @Test("ID lookup for a stale or missing pane renders as a plain rail")
    func focusAccentIDLookupFallsBackToIdle() {
        let idle = TerminalPane(
            title: "shell", workingDirectory: "~", agentKind: .shell,
            shellActivity: .idle,
            executionPlan: .local
        )
        let session = TerminalSession(
            title: "shell", workingDirectory: "~",
            layout: .pane(idle), activePaneID: idle.id
        )

        #expect(session.focusAccentAwState(forPaneID: UUID()) == .idle)
    }
}
