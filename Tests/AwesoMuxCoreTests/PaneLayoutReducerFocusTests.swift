import Foundation
import Testing
@testable import AwesoMuxCore

@Suite("PaneLayoutReducer focus by index")
struct PaneLayoutReducerFocusTests {
    /// Depth-first pane order is [first, second, third].
    private func makeThreePaneSession(
        active: (TerminalPane, TerminalPane, TerminalPane) -> TerminalPane
    ) -> (session: TerminalSession, panes: (TerminalPane, TerminalPane, TerminalPane)) {
        let first = TerminalPane(title: "first", workingDirectory: "/a", executionPlan: .local)
        let second = TerminalPane(title: "second", workingDirectory: "/b", executionPlan: .local)
        let third = TerminalPane(title: "third", workingDirectory: "/c", executionPlan: .local)
        let layout = TerminalPaneLayout.split(TerminalSplit(
            orientation: .vertical,
            first: .split(TerminalSplit(
                orientation: .horizontal,
                first: .pane(first),
                second: .pane(second)
            )),
            second: .pane(third)
        ))
        let activePane = active(first, second, third)
        let session = TerminalSession(
            title: "workspace",
            workingDirectory: activePane.workingDirectory,
            agentKind: .shell,
            layout: layout,
            activePaneID: activePane.id
        )
        return (session, (first, second, third))
    }

    @Test("focusPane(at:) selects the Nth pane depth-first and syncs chrome")
    func focusesNthPane() throws {
        let (session, panes) = makeThreePaneSession { _, second, _ in second }
        let updated = try #require(PaneLayoutReducer.focusPane(at: 1, in: session))
        #expect(updated.activePaneID == panes.0.id)
        #expect(updated.workingDirectory == "/a")
        #expect(updated.title == "first")
    }

    @Test("focusPane(at:) reaches the last pane")
    func focusesLastPane() throws {
        let (session, panes) = makeThreePaneSession { first, _, _ in first }
        let updated = try #require(PaneLayoutReducer.focusPane(at: 3, in: session))
        #expect(updated.activePaneID == panes.2.id)
        #expect(updated.workingDirectory == "/c")
    }

    @Test("focusPane(at:) returns nil when the target is already active")
    func nilWhenAlreadyActive() {
        let (session, _) = makeThreePaneSession { _, second, _ in second }
        #expect(PaneLayoutReducer.focusPane(at: 2, in: session) == nil)
    }

    @Test("focusPane(at:) returns nil for out-of-range indices")
    func nilWhenOutOfRange() {
        let (session, _) = makeThreePaneSession { first, _, _ in first }
        #expect(PaneLayoutReducer.focusPane(at: 0, in: session) == nil)
        #expect(PaneLayoutReducer.focusPane(at: 4, in: session) == nil)
    }

    @Test("focusPane(at:) returns nil on a single-pane session")
    func nilForSinglePane() {
        let pane = TerminalPane(title: "only", workingDirectory: "~", executionPlan: .local)
        let session = TerminalSession(
            title: "workspace",
            workingDirectory: "~",
            agentKind: .shell,
            layout: .pane(pane),
            activePaneID: pane.id
        )
        #expect(PaneLayoutReducer.focusPane(at: 1, in: session) == nil)
    }
}
