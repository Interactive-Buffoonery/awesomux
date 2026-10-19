import Foundation
import Testing
@testable import AwesoMuxCore

@MainActor
@Suite("Shell activity (INT-333)")
struct ShellActivityTests {
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

    @Test(arguments: [false, true])
    func shellActivityORFoldsPaneReadingsAndDebouncesTransitions(briefBusyBlip: Bool) throws {
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

        if briefBusyBlip {
            store.updateShellActivity([.active(shell, isBusy: false)], now: t0.addingTimeInterval(0.05))
            #expect(store.session(id: shell.id)?.shellActivity == .idle)
            #expect(store.session(id: shell.id)?.effectiveChromeState == .idle)
            return
        }

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

    @Test("an unseen pane cannot force a split session to running")
    func unseenSplitPaneCannotForceSessionRunning() {
        let t0 = Date(timeIntervalSinceReferenceDate: 6_000)
        let paneAObj = TerminalPane(title: "a", workingDirectory: "~", agentKind: .shell, executionPlan: .local)
        let paneBObj = TerminalPane(title: "b", workingDirectory: "~", agentKind: .shell, executionPlan: .local)
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
        #expect(store.session(id: shell.id)?.layout.pane(id: paneA)?.shellActivity == .idle)
        #expect(store.session(id: shell.id)?.effectiveChromeState == .running)
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
