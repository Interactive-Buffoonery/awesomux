import Foundation
import Testing
@testable import AwesoMuxCore

@MainActor
@Suite("Shell activity (INT-333)")
struct ShellActivityTests {
    @Test("new shell sessions start idle while agent sessions start running")
    func newSessionsUseAgentKindInitialState() {
        let store = SessionStore(groups: [])

        let shellID = store.addSession(title: "shell", agentKind: .shell)
        #expect(store.session(id: shellID)?.agentState == .idle)
        #expect(store.session(id: shellID)?.effectiveChromeState == .idle)

        let codexID = store.addSession(title: "codex", agentKind: .codex)
        #expect(store.session(id: codexID)?.agentState == .running)
        #expect(store.session(id: codexID)?.effectiveChromeState == .running)
    }

    @Test("cold stores stay empty while floating panel sessions start idle")
    func coldStoresStayEmptyWhileFloatingPanelSessionsStartIdle() {
        let defaultStore = SessionStore()
        #expect(defaultStore.groups.isEmpty)
        #expect(defaultStore.selectedSession == nil)

        let floatingStore = FloatingPanelStoreFactory.makeStore(
            parentWorkspace: nil,
            fallbackHome: "/Users/example"
        )
        #expect(floatingStore.selectedSession?.agentKind == .shell)
        #expect(floatingStore.selectedSession?.agentState == .idle)
    }

    @Test("acknowledging a shell workspace returns it to idle")
    func acknowledgingShellWorkspaceReturnsToIdle() {
        let shell = TerminalSession(
            title: "shell",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .needsAttention,
            unreadNotificationCount: 1
        )
        let codex = TerminalSession(
            title: "codex",
            workingDirectory: "~",
            agentKind: .codex,
            agentState: .needsAttention,
            unreadNotificationCount: 1
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "main", sessions: [shell, codex])
        ])

        store.acknowledgeSession(id: shell.id)
        store.acknowledgeSession(id: codex.id)

        #expect(store.session(id: shell.id)?.agentState == .idle)
        #expect(store.session(id: codex.id)?.agentState == .running)
    }

    @Test("recycling a shell pane clears shell activity and quit risk")
    func recyclingShellPaneClearsShellActivityAndQuitRisk() {
        let shell = TerminalSession(
            title: "shell",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .done,
            needsTerminalQuitConfirmation: true,
            shellActivity: .busy
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "main", sessions: [shell])
        ])

        store.recycleActivePane(in: shell.id)

        let recycled = store.session(id: shell.id)
        #expect(recycled?.agentState == .idle)
        #expect(recycled?.shellActivity == .idle)
        #expect(recycled?.needsTerminalQuitConfirmation == false)
        #expect(recycled?.effectiveChromeState == .idle)
    }

    @Test("shell chrome state is activity-derived while agent chrome uses agent state")
    func effectiveChromeStateSplitsShellActivityFromAgentState() {
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
        let waitingAgent = TerminalSession(
            title: "codex",
            workingDirectory: "~",
            agentKind: .codex,
            agentState: .waiting,
            shellActivity: .busy
        )
        let heldShell = TerminalSession(
            title: "shell",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .done,
            shellActivity: .busy
        )

        #expect(idleShell.effectiveChromeState == .idle)
        #expect(busyShell.effectiveChromeState == .running)
        #expect(waitingAgent.effectiveChromeState == .waiting)
        #expect(heldShell.effectiveChromeState == .idle)
    }

    @Test("shell activity OR-folds pane readings and debounces transitions")
    func shellActivityORFoldsPaneReadingsAndDebouncesTransitions() throws {
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
        let shell = TerminalSession(
            title: "shell",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .idle
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "main", sessions: [shell])
        ])

        // The idle reading in this batch seeds the pane's prompt-seen trust, so
        // the busy reading in the same batch is honored.
        let pendingBusy = store.updateShellActivity([
            .active(shell, isBusy: false),
            .active(shell, isBusy: true),
        ], now: t0)
        #expect(pendingBusy)
        #expect(store.session(id: shell.id)?.shellActivity == .idle)

        let committedBusy = store.updateShellActivity(
            [.active(shell, isBusy: true)],
            now: t0.addingTimeInterval(SessionStore.shellActivityBusyDebounceInterval)
        )
        #expect(!committedBusy)
        #expect(store.session(id: shell.id)?.shellActivity == .busy)
        #expect(store.session(id: shell.id)?.effectiveChromeState == .running)

        let pendingIdle = store.updateShellActivity(
            [.active(shell, isBusy: false)],
            now: t0.addingTimeInterval(0.30)
        )
        #expect(pendingIdle)
        #expect(store.session(id: shell.id)?.shellActivity == .busy)

        let committedIdle = store.updateShellActivity(
            [.active(shell, isBusy: false)],
            now: t0.addingTimeInterval(0.30 + SessionStore.shellActivityIdleDebounceInterval)
        )
        #expect(!committedIdle)
        #expect(store.session(id: shell.id)?.shellActivity == .idle)
        #expect(store.session(id: shell.id)?.effectiveChromeState == .idle)
    }

    // Encodes the INT-333 design decision (option A): shell chrome is a
    // sustained-activity indicator, so work shorter than the busy debounce
    // interval intentionally never surfaces as Running. This is deliberate, not
    // flicker-prevention happenstance — if shell chrome ever switches to
    // per-command semantics, this expectation is the signpost that must change.
    @Test("brief busy blips do not surface as running chrome")
    func briefBusyBlipsDoNotSurfaceAsRunningChrome() {
        let t0 = Date(timeIntervalSinceReferenceDate: 2_000)
        let shell = TerminalSession(
            title: "shell",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .idle
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "main", sessions: [shell])
        ])

        // Seed prompt-seen trust with an idle sample so the busy blip is honored
        // far enough to enter the debounce — otherwise the trust gate would
        // suppress it and this test would silently exercise that gate instead of
        // the busy-debounce it claims. The pending return asserts the blip is in
        // the debounce, not trust-gated.
        store.updateShellActivity([.active(shell, isBusy: false)], now: t0)
        let pendingBusy = store.updateShellActivity(
            [.active(shell, isBusy: true)],
            now: t0.addingTimeInterval(0.01)
        )
        #expect(pendingBusy)
        store.updateShellActivity([.active(shell, isBusy: false)], now: t0.addingTimeInterval(0.05))

        #expect(store.session(id: shell.id)?.shellActivity == .idle)
        #expect(store.session(id: shell.id)?.effectiveChromeState == .idle)
    }

    @Test("busy samples before any prompt observation stay idle")
    func busySamplesBeforeAnyPromptObservationStayIdle() {
        let t0 = Date(timeIntervalSinceReferenceDate: 3_000)
        let shell = TerminalSession(
            title: "shell",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .idle
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "main", sessions: [shell])
        ])

        // The pane never reports at a prompt, so its busy marker is never
        // trusted — broken/absent shell integration must not show Running.
        store.updateShellActivity([.active(shell, isBusy: true)], now: t0)
        store.updateShellActivity(
            [.active(shell, isBusy: true)],
            now: t0.addingTimeInterval(SessionStore.shellActivityBusyDebounceInterval * 2)
        )

        #expect(store.session(id: shell.id)?.shellActivity == .idle)
        #expect(store.session(id: shell.id)?.effectiveChromeState == .idle)
    }

    @Test("prompt sample before submit allows first command to become busy")
    func promptSampleBeforeSubmitAllowsFirstCommandToBecomeBusy() {
        let t0 = Date(timeIntervalSinceReferenceDate: 3_500)
        let shell = TerminalSession(
            title: "shell",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .idle
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "main", sessions: [shell])
        ])

        store.updateShellActivity([.active(shell, isBusy: false)], now: t0)
        let pendingBusy = store.updateShellActivity(
            [.active(shell, isBusy: true)],
            now: t0.addingTimeInterval(0.15)
        )
        #expect(pendingBusy)
        #expect(store.session(id: shell.id)?.shellActivity == .idle)

        let committedBusy = store.updateShellActivity(
            [.active(shell, isBusy: true)],
            now: t0.addingTimeInterval(0.15 + SessionStore.shellActivityBusyDebounceInterval)
        )
        #expect(!committedBusy)
        #expect(store.session(id: shell.id)?.shellActivity == .busy)
        #expect(store.session(id: shell.id)?.effectiveChromeState == .running)
    }

    @Test("busy shell returns idle after repeated false samples")
    func busyShellReturnsIdleAfterRepeatedFalseSamples() {
        let t0 = Date(timeIntervalSinceReferenceDate: 4_000)
        let shell = TerminalSession(
            title: "shell",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .idle
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "main", sessions: [shell])
        ])

        store.updateShellActivity([.active(shell, isBusy: false)], now: t0)
        store.updateShellActivity(
            [.active(shell, isBusy: true)],
            now: t0.addingTimeInterval(0.15)
        )
        store.updateShellActivity(
            [.active(shell, isBusy: true)],
            now: t0.addingTimeInterval(0.15 + SessionStore.shellActivityBusyDebounceInterval)
        )
        #expect(store.session(id: shell.id)?.shellActivity == .busy)

        let pendingIdle = store.updateShellActivity(
            [.active(shell, isBusy: false)],
            now: t0.addingTimeInterval(0.50)
        )
        #expect(pendingIdle)
        #expect(store.session(id: shell.id)?.shellActivity == .busy)

        let committedIdle = store.updateShellActivity(
            [.active(shell, isBusy: false)],
            now: t0.addingTimeInterval(0.50 + SessionStore.shellActivityIdleDebounceInterval + 0.001)
        )
        #expect(!committedIdle)
        #expect(store.session(id: shell.id)?.shellActivity == .idle)
        #expect(store.session(id: shell.id)?.effectiveChromeState == .idle)
    }

    @Test("one busy pane in a split folds the session rollup to running")
    func trustedSplitPanesORFoldToSessionBusy() {
        let t0 = Date(timeIntervalSinceReferenceDate: 5_000)
        let paneAObj = TerminalPane(title: "a", workingDirectory: "~", agentKind: .shell)
        let paneBObj = TerminalPane(title: "b", workingDirectory: "~", agentKind: .shell)
        let shell = TerminalSession(
            title: "shell",
            workingDirectory: "~",
            layout: .split(TerminalSplit(
                orientation: .vertical,
                first: .pane(paneAObj),
                second: .pane(paneBObj)
            )),
            activePaneID: paneAObj.id
        )
        let paneA = paneAObj.id
        let paneB = paneBObj.id
        let store = SessionStore(groups: [
            SessionGroup(name: "main", sessions: [shell])
        ])

        // Both panes reach a prompt → both trusted.
        store.updateShellActivity([
            ShellActivitySnapshot(sessionID: shell.id, paneID: paneA, isBusy: false),
            ShellActivitySnapshot(sessionID: shell.id, paneID: paneB, isBusy: false),
        ], now: t0)

        // Pane B goes busy; one trusted busy pane folds the session rollup to busy.
        store.updateShellActivity([
            ShellActivitySnapshot(sessionID: shell.id, paneID: paneA, isBusy: false),
            ShellActivitySnapshot(sessionID: shell.id, paneID: paneB, isBusy: true),
        ], now: t0.addingTimeInterval(0.05))
        store.updateShellActivity([
            ShellActivitySnapshot(sessionID: shell.id, paneID: paneA, isBusy: false),
            ShellActivitySnapshot(sessionID: shell.id, paneID: paneB, isBusy: true),
        ], now: t0.addingTimeInterval(0.05 + SessionStore.shellActivityBusyDebounceInterval))

        let live = store.session(id: shell.id)
        // Activity is now per pane: only pane B is busy; pane A stays idle.
        #expect(live?.layout.pane(id: paneA)?.shellActivity == .idle)
        #expect(live?.layout.pane(id: paneB)?.shellActivity == .busy)
        // The session rollup still surfaces the busy pane as Running.
        #expect(live?.effectiveChromeState == .running)
    }

    @Test("an unseen pane cannot force a split session to running")
    func unseenSplitPaneCannotForceSessionRunning() {
        let t0 = Date(timeIntervalSinceReferenceDate: 6_000)
        let paneAObj = TerminalPane(title: "a", workingDirectory: "~", agentKind: .shell)
        let paneBObj = TerminalPane(title: "b", workingDirectory: "~", agentKind: .shell)
        let shell = TerminalSession(
            title: "shell",
            workingDirectory: "~",
            layout: .split(TerminalSplit(
                orientation: .vertical,
                first: .pane(paneAObj),
                second: .pane(paneBObj)
            )),
            activePaneID: paneAObj.id
        )
        let paneA = paneAObj.id
        let paneB = paneBObj.id
        let store = SessionStore(groups: [
            SessionGroup(name: "main", sessions: [shell])
        ])

        // Pane A reaches a prompt (trusted, idle). Pane B never reaches a prompt
        // (e.g. missing shell integration) and is permanently busy. The per-pane
        // trust gate must keep B idle no matter how long it stays busy — a sibling
        // reaching a prompt cannot authorize B.
        store.updateShellActivity([
            ShellActivitySnapshot(sessionID: shell.id, paneID: paneA, isBusy: false),
            ShellActivitySnapshot(sessionID: shell.id, paneID: paneB, isBusy: true),
        ], now: t0)
        store.updateShellActivity([
            ShellActivitySnapshot(sessionID: shell.id, paneID: paneA, isBusy: false),
            ShellActivitySnapshot(sessionID: shell.id, paneID: paneB, isBusy: true),
        ], now: t0.addingTimeInterval(SessionStore.shellActivityBusyDebounceInterval * 2))

        #expect(store.session(id: shell.id)?.layout.pane(id: paneB)?.shellActivity == .idle)
        #expect(store.session(id: shell.id)?.effectiveChromeState == .idle)

        // Once pane B finally reaches a prompt, its later busy marker is trusted.
        let seenAt = t0.addingTimeInterval(1.0)
        store.updateShellActivity([
            ShellActivitySnapshot(sessionID: shell.id, paneID: paneB, isBusy: false)
        ], now: seenAt)
        store.updateShellActivity([
            ShellActivitySnapshot(sessionID: shell.id, paneID: paneB, isBusy: true)
        ], now: seenAt.addingTimeInterval(0.01))
        store.updateShellActivity([
            ShellActivitySnapshot(sessionID: shell.id, paneID: paneB, isBusy: true)
        ], now: seenAt.addingTimeInterval(0.01 + SessionStore.shellActivityBusyDebounceInterval))

        #expect(store.session(id: shell.id)?.layout.pane(id: paneB)?.shellActivity == .busy)
    }

    @Test("a recycled pane must re-earn prompt trust before busy counts")
    func recycledPaneReEarnsTrustBeforeBusy() throws {
        let t0 = Date(timeIntervalSinceReferenceDate: 7_000)
        let shell = TerminalSession(
            title: "shell",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .idle
        )
        let originalPane = shell.activePaneID
        let store = SessionStore(groups: [
            SessionGroup(name: "main", sessions: [shell])
        ])

        // Original pane earns trust at a prompt.
        store.updateShellActivity([
            ShellActivitySnapshot(sessionID: shell.id, paneID: originalPane, isBusy: false)
        ], now: t0)

        store.recycleActivePane(in: shell.id)
        let freshPane = try #require(store.session(id: shell.id)?.activePaneID)
        #expect(freshPane != originalPane)

        // The fresh pane reports busy without ever reaching a prompt — recycle
        // dropped the old pane's trust and the new pane hasn't earned it, so it
        // must stay idle.
        store.updateShellActivity([
            ShellActivitySnapshot(sessionID: shell.id, paneID: freshPane, isBusy: true)
        ], now: t0.addingTimeInterval(0.01))
        store.updateShellActivity([
            ShellActivitySnapshot(sessionID: shell.id, paneID: freshPane, isBusy: true)
        ], now: t0.addingTimeInterval(0.01 + SessionStore.shellActivityBusyDebounceInterval * 2))
        #expect(store.session(id: shell.id)?.shellActivity == .idle)
    }

    @Test("closing a split pane preserves the surviving pane's trust")
    func closingSplitPanePreservesSurvivingPaneTrust() throws {
        let t0 = Date(timeIntervalSinceReferenceDate: 8_000)
        let shell = TerminalSession(
            title: "shell",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .idle
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "main", sessions: [shell])
        ])
        let paneA = shell.activePaneID
        let paneB = try #require(
            store.splitActivePane(orientation: .vertical, in: shell.id)
        )

        // Both panes reach a prompt → both trusted.
        store.updateShellActivity([
            ShellActivitySnapshot(sessionID: shell.id, paneID: paneA, isBusy: false),
            ShellActivitySnapshot(sessionID: shell.id, paneID: paneB, isBusy: false),
        ], now: t0)

        store.closePane(id: paneB, in: shell.id)

        // The survivor (paneA) keeps its trust — closing its sibling must not
        // strip it. Its busy marker still surfaces as Running.
        store.updateShellActivity([
            ShellActivitySnapshot(sessionID: shell.id, paneID: paneA, isBusy: true)
        ], now: t0.addingTimeInterval(0.01))
        store.updateShellActivity([
            ShellActivitySnapshot(sessionID: shell.id, paneID: paneA, isBusy: true)
        ], now: t0.addingTimeInterval(0.01 + SessionStore.shellActivityBusyDebounceInterval))
        #expect(store.session(id: shell.id)?.shellActivity == .busy)
    }

    @Test("quit risk remains raw and immediate")
    func quitRiskRemainsRawAndImmediate() {
        let shell = TerminalSession(
            title: "shell",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .idle
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "main", sessions: [shell])
        ])

        store.updateTerminalQuitConfirmationRisks([.active(shell, needsConfirmation: true)])

        let updated = store.session(id: shell.id)
        #expect(updated?.needsTerminalQuitConfirmation == true)
        #expect(updated?.shellActivity == .idle)
        #expect(updated?.isQuitRisk() == true)
    }
}
