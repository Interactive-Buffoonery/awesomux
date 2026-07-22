import AwesoMuxBridgeProtocol
import AwesoMuxCore
import DesignSystem
import Testing
@testable import awesoMux

@Suite("Pane peek items (INT-538)")
struct PanePeekItemTests {
    private func pane(
        _ title: String,
        cwd: String = "~",
        kind: AgentKind = .shell,
        execution: AgentExecutionState = .idle,
        attention: AttentionReason? = nil,
        unread: Int = 0,
        remoteHost: String? = nil
    ) -> TerminalPane {
        TerminalPane(
            title: title,
            workingDirectory: cwd,
            remoteHost: remoteHost,
            agentKind: kind,
            agentExecutionState: execution,
            attentionReason: attention,
            unreadNotificationCount: unread,
            executionPlan: .local
        )
    }

    private func split(_ panes: [TerminalPane]) -> TerminalPaneLayout {
        precondition(panes.count >= 2)
        // Right-leaning nest so paneIDs traversal order is the array order.
        var layout = TerminalPaneLayout.pane(panes[panes.count - 1])
        for pane in panes.dropLast().reversed() {
            layout = .split(TerminalSplit(
                orientation: .vertical,
                first: .pane(pane),
                second: layout
            ))
        }
        return layout
    }

    @Test("Single-pane session yields one item, flagged active, numbered 1")
    func singlePane() {
        let only = pane("zsh")
        let session = TerminalSession(
            title: "ws", workingDirectory: "~",
            layout: .pane(only), activePaneID: only.id
        )
        let items = PanePeekItem.items(for: session)
        #expect(items.count == 1)
        #expect(items[0].isActive)
        #expect(items[0].paneNumber == 1)
    }

    @Test("Item order and pane numbers match layout.paneIDs")
    func orderAndNumbers() {
        let panes = [pane("a"), pane("b"), pane("c")]
        let layout = split(panes)
        let session = TerminalSession(
            title: "ws", workingDirectory: "~",
            layout: layout, activePaneID: layout.firstPaneID
        )
        let items = PanePeekItem.items(for: session)
        #expect(items.map(\.id) == session.layout.paneIDs)
        #expect(items.map(\.paneNumber) == [1, 2, 3])
    }

    @Test("Active flag tracks activePaneID, not just the first pane")
    func activeFlag() {
        let panes = [pane("a"), pane("b")]
        let layout = split(panes)
        let session = TerminalSession(
            title: "ws", workingDirectory: "~",
            layout: layout, activePaneID: panes[1].id
        )
        let items = PanePeekItem.items(for: session)
        #expect(items.filter(\.isActive).map(\.id) == [panes[1].id])
    }

    @Test("Empty title falls back to cwd basename")
    func titleFallback() {
        let only = pane("   ", cwd: "/Users/x/Development/awesomux")
        let session = TerminalSession(
            title: "ws", workingDirectory: "~",
            layout: .pane(only), activePaneID: only.id
        )
        #expect(PanePeekItem.items(for: session)[0].title == "awesomux")
    }

    @Test("Peek item title matches the pane title bar display title")
    func titleMatchesPaneTitleBarDisplayTitle() {
        let only = pane("   ", cwd: "/Users/x/Development/awesomux")
        let session = TerminalSession(
            title: "ws", workingDirectory: "~",
            layout: .pane(only), activePaneID: only.id
        )

        #expect(
            PanePeekItem.items(for: session)[0].title
                == PaneTitleBarView.displayTitle(for: only)
        )
    }

    @Test("Per-pane state diverges — one needy pane does not make its sibling needy")
    func perPaneStateDiverges() {
        let needy = pane("codex", kind: .codex, attention: .permissionPrompt)
        let calm = pane("claude", kind: .claudeCode, execution: .idle)
        let layout = split([needy, calm])
        let session = TerminalSession(
            title: "ws", workingDirectory: "~",
            layout: layout, activePaneID: calm.id
        )
        let items = PanePeekItem.items(for: session)
        #expect(items[0].state == .needs)
        #expect(items[1].state == .idle)
    }

    @Test("Per-pane unread maps from each pane's own count")
    func perPaneUnread() {
        let loud = pane("a", kind: .codex, unread: 3)
        let quiet = pane("b", kind: .codex, unread: 0)
        let layout = split([loud, quiet])
        let session = TerminalSession(
            title: "ws", workingDirectory: "~",
            layout: layout, activePaneID: loud.id
        )
        let items = PanePeekItem.items(for: session)
        #expect(items[0].unread == 3)
        #expect(items[1].unread == 0)
    }

    @Test("Per-pane icon follows each pane's agent kind")
    func perPaneIcon() {
        let codex = pane("a", kind: .codex)
        let claude = pane("b", kind: .claudeCode)
        let layout = split([codex, claude])
        let session = TerminalSession(
            title: "ws", workingDirectory: "~",
            layout: layout, activePaneID: codex.id
        )
        let items = PanePeekItem.items(for: session)
        #expect(items[0].agent == .codex)
        #expect(items[1].agent == .claude)
        // Short name rides along for the VoiceOver jump-action label.
        #expect(items[0].agentShortName == "Codex")
        #expect(items[1].agentShortName == "Claude")
    }

    @Test("Items compare unequal when only a pane's state changes")
    func stateChangeBreaksEquality() {
        // The peek-card refresh rides on PanePeekItem Equatable: peekRefreshKey
        // folds [PanePeekItem], so onChange must see a per-pane state flip even
        // when the session aggregate is unchanged. Pin it so a future AwState
        // change that drops Equatable can't silently strand a stale card.
        let calm = pane("a", kind: .codex, execution: .idle)
        let calmSession = TerminalSession(
            title: "ws", workingDirectory: "~",
            layout: .pane(calm), activePaneID: calm.id
        )
        let busy = TerminalPane(
            id: calm.id, title: "a", workingDirectory: "~",
            agentKind: .codex, agentExecutionState: .running,
            executionPlan: .local
        )
        let busySession = TerminalSession(
            title: "ws", workingDirectory: "~",
            layout: .pane(busy), activePaneID: busy.id
        )

        #expect(PanePeekItem.items(for: calmSession) != PanePeekItem.items(for: busySession))
    }

    @Test("Root-cwd fallback yields a non-empty title, never crashes")
    func rootCwdFallback() {
        let only = pane("", cwd: "/")
        let session = TerminalSession(
            title: "ws", workingDirectory: "~",
            layout: .pane(only), activePaneID: only.id
        )
        // basename of "/" is "/" — non-empty, so the row still renders a glyph.
        #expect(PanePeekItem.items(for: session)[0].title == "/")
    }

    @Test("Remote flag tracks per-pane remoteHost")
    func remoteFlag() {
        let local = pane("a")
        let remote = pane("b", remoteHost: "devbox")
        let layout = split([local, remote])
        let session = TerminalSession(
            title: "ws", workingDirectory: "~",
            layout: layout, activePaneID: local.id
        )
        let items = PanePeekItem.items(for: session)
        #expect(!items[0].isRemote)
        #expect(items[1].isRemote)
        #expect(items[1].remoteHost == "devbox")
    }

    @Test("declared SSH target names remote pane before prompt observation")
    func declaredSSHNamesRemotePaneBeforeObservation() {
        let target = RemoteTarget(user: "alice", host: "buildbox-alias")!
        let remote = TerminalPane(
            title: "remote",
            workingDirectory: "/srv/app",
            executionPlan: .ssh(SSHExecution(target: target))
        )
        let session = TerminalSession(
            title: "ws",
            workingDirectory: "~",
            layout: .pane(remote),
            activePaneID: remote.id
        )

        let item = PanePeekItem.items(for: session)[0]

        #expect(item.isRemote)
        #expect(item.remoteHost == "alice@buildbox-alias")
    }
}
