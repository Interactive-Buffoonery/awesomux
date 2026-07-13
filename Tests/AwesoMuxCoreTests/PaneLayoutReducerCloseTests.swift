import Foundation
import Testing
@testable import AwesoMuxCore

@Suite("PaneLayoutReducer close and active pane")
struct PaneLayoutReducerCloseTests {
    @Test("closePane returns session result when closing last pane")
    func closePaneReturnsSessionForLastPane() {
        let pane = TerminalPane(title: "only", workingDirectory: "~", executionPlan: .local)
        let session = TerminalSession(
            title: "workspace",
            workingDirectory: "~",
            agentKind: .shell,
            layout: .pane(pane),
            activePaneID: pane.id
        )

        let result = PaneLayoutReducer.closePane(id: pane.id, in: session)
        #expect(result != nil)
        #expect(result?.result == .session(session.id, paneIDs: [pane.id]))
        #expect(result?.session == nil)
    }

    @Test("closePane picks adjacent pane as replacement when active pane is closed")
    func closePanePicksAdjacentReplacement() throws {
        let first = TerminalPane(title: "first", workingDirectory: "/a", executionPlan: .local)
        let second = TerminalPane(title: "second", workingDirectory: "/b", executionPlan: .local)
        let third = TerminalPane(title: "third", workingDirectory: "/c", executionPlan: .local)
        let leftSplit = TerminalSplit(
            orientation: .vertical,
            first: .pane(first),
            second: .pane(second)
        )
        let layout = TerminalPaneLayout.split(TerminalSplit(
            orientation: .horizontal,
            first: .split(leftSplit),
            second: .pane(third)
        ))
        let session = TerminalSession(
            title: "workspace",
            workingDirectory: "/b",
            agentKind: .shell,
            layout: layout,
            activePaneID: second.id
        )

        let result = try #require(PaneLayoutReducer.closePane(id: second.id, in: session))
        if case .pane = result.result {
            let updated = try #require(result.session)
            #expect(!updated.layout.paneIDs.contains(second.id))
            #expect(updated.activePaneID == third.id)
            #expect(updated.workingDirectory == "/c")
        } else {
            Issue.record("Expected .pane result for multi-pane close")
        }
    }

    @Test("closePane keeps current active when closing non-active pane")
    func closePaneKeepsActiveWhenClosingOther() throws {
        let first = TerminalPane(title: "first", workingDirectory: "/a", executionPlan: .local)
        let second = TerminalPane(title: "second", workingDirectory: "/b", executionPlan: .local)
        let layout = TerminalPaneLayout.split(TerminalSplit(
            orientation: .vertical,
            first: .pane(first),
            second: .pane(second)
        ))
        let session = TerminalSession(
            title: "workspace",
            workingDirectory: "/a",
            agentKind: .shell,
            layout: layout,
            activePaneID: first.id
        )

        let result = try #require(PaneLayoutReducer.closePane(id: second.id, in: session))
        if case .pane = result.result {
            let updated = try #require(result.session)
            #expect(updated.activePaneID == first.id)
        } else {
            Issue.record("Expected .pane result")
        }
    }

    @Test("closePane adopts a surviving user-edited pane title after split collapse")
    func closePaneAdoptsSurvivingUserEditedPaneTitle() throws {
        var surviving = TerminalPane(title: "My Backend", workingDirectory: "/a", executionPlan: .local)
        surviving.isTitleUserEdited = true
        let closing = TerminalPane(title: "logs", workingDirectory: "/b", executionPlan: .local)
        let layout = TerminalPaneLayout.split(TerminalSplit(
            orientation: .vertical,
            first: .pane(surviving),
            second: .pane(closing)
        ))
        let session = TerminalSession(
            title: "stale workspace title",
            workingDirectory: "/b",
            agentKind: .shell,
            layout: layout,
            activePaneID: closing.id
        )

        let result = try #require(PaneLayoutReducer.closePane(id: closing.id, in: session))
        let updated = try #require(result.session)

        #expect(updated.layout.paneIDs == [surviving.id])
        #expect(updated.activePaneID == surviving.id)
        #expect(updated.title == "My Backend")
    }

    @Test("setActivePane syncs session chrome to new active pane")
    func setActivePaneSyncsChrome() throws {
        let first = TerminalPane(title: "first", workingDirectory: "/a", executionPlan: .local)
        let second = TerminalPane(title: "second", workingDirectory: "/b", executionPlan: .local)
        let layout = TerminalPaneLayout.split(TerminalSplit(
            orientation: .vertical,
            first: .pane(first),
            second: .pane(second)
        ))
        let session = TerminalSession(
            title: "first",
            workingDirectory: "/a",
            agentKind: .shell,
            layout: layout,
            activePaneID: first.id
        )

        let updated = try #require(PaneLayoutReducer.setActivePane(id: second.id, in: session))
        #expect(updated.activePaneID == second.id)
        #expect(updated.workingDirectory == "/b")
        #expect(updated.title == "second")
    }

    @Test("setActivePane returns nil for same pane")
    func setActivePaneReturnsNilForSamePane() {
        let pane = TerminalPane(title: "only", workingDirectory: "~", executionPlan: .local)
        let session = TerminalSession(
            title: "workspace",
            workingDirectory: "~",
            agentKind: .shell,
            layout: .pane(pane),
            activePaneID: pane.id
        )
        #expect(PaneLayoutReducer.setActivePane(id: pane.id, in: session) == nil)
    }

    @Test("setActivePane returns nil for nonexistent pane")
    func setActivePaneReturnsNilForMissingPane() {
        let pane = TerminalPane(title: "only", workingDirectory: "~", executionPlan: .local)
        let session = TerminalSession(
            title: "workspace",
            workingDirectory: "~",
            agentKind: .shell,
            layout: .pane(pane),
            activePaneID: pane.id
        )
        #expect(PaneLayoutReducer.setActivePane(id: UUID(), in: session) == nil)
    }
}
