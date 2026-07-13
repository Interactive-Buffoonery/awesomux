import Foundation
import Testing
@testable import AwesoMuxCore

@MainActor
@Suite
struct SetPaneColorTests {
    private func splitSession() -> (TerminalSession, TerminalPane.ID, TerminalPane.ID) {
        let left = TerminalPane(title: "left", workingDirectory: "/l", executionPlan: .local)
        let right = TerminalPane(title: "right", workingDirectory: "/r", executionPlan: .local)
        let session = TerminalSession(
            title: "ws",
            workingDirectory: "~",
            layout: .split(.init(orientation: .horizontal, first: .pane(left),
                                 second: .pane(right), firstFraction: 0.5))
        )
        return (session, left.id, right.id)
    }

    @Test
    func setsColorOnTargetPaneOnly() throws {
        let (session, leftID, rightID) = splitSession()
        let updated = try #require(
            PaneLayoutReducer.setPaneColor(in: session, paneID: leftID, color: .palette(.teal))
        )
        #expect(updated.layout.pane(id: leftID)?.color == .palette(.teal))
        #expect(updated.layout.pane(id: rightID)?.color == nil)
    }

    @Test
    func clearsColorWithNil() throws {
        let (session, leftID, _) = splitSession()
        let colored = try #require(
            PaneLayoutReducer.setPaneColor(in: session, paneID: leftID, color: .palette(.teal))
        )
        let cleared = try #require(
            PaneLayoutReducer.setPaneColor(in: colored, paneID: leftID, color: nil)
        )
        #expect(cleared.layout.pane(id: leftID)?.color == nil)
    }

    @Test
    func returnsNilWhenUnchanged() {
        let (session, leftID, _) = splitSession()
        #expect(PaneLayoutReducer.setPaneColor(in: session, paneID: leftID, color: nil) == nil)
    }

    @Test
    func returnsNilForAbsentPane() {
        let (session, _, _) = splitSession()
        #expect(PaneLayoutReducer.setPaneColor(in: session, paneID: UUID(), color: .palette(.sky)) == nil)
    }

    @Test
    func facadeCommitsAndReports() throws {
        let (session, leftID, _) = splitSession()
        let store = SessionStore(groups: [SessionGroup(name: "g", sessions: [session])],
                                 selectedSessionID: session.id)
        #expect(store.setPaneColor(sessionID: session.id, paneID: leftID, color: .palette(.pink)) == true)
        // Readback: color must actually be stored after the first call.
        let storedColor = try #require(store.session(id: session.id)?.layout.pane(id: leftID)?.color)
        #expect(storedColor == .palette(.pink))
        // Idempotent success: a second identical call returns true (pane exists),
        // not false — matches setGroupColor's contract.
        #expect(store.setPaneColor(sessionID: session.id, paneID: leftID, color: .palette(.pink)) == true)
    }

    @Test
    func returnsFalseForAbsentPaneViaFacade() {
        let (session, _, _) = splitSession()
        let store = SessionStore(groups: [SessionGroup(name: "g", sessions: [session])],
                                 selectedSessionID: session.id)
        #expect(store.setPaneColor(sessionID: session.id, paneID: UUID(), color: .palette(.sky)) == false)
    }

    @Test
    func setsColorOnDeepPaneInNestedSplit() throws {
        // Tree: root split → (left pane, inner split → (innerLeft, innerRight))
        // Confirms the reducer walks more than one level deep.
        let left = TerminalPane(title: "left", workingDirectory: "/l", executionPlan: .local)
        let innerLeft = TerminalPane(title: "innerLeft", workingDirectory: "/il", executionPlan: .local)
        let innerRight = TerminalPane(title: "innerRight", workingDirectory: "/ir", executionPlan: .local)
        let innerSplit = TerminalSplit(
            orientation: .horizontal,
            first: .pane(innerLeft),
            second: .pane(innerRight),
            firstFraction: 0.5
        )
        let session = TerminalSession(
            title: "ws",
            workingDirectory: "~",
            layout: .split(TerminalSplit(
                orientation: .vertical,
                first: .pane(left),
                second: .split(innerSplit),
                firstFraction: 0.5
            ))
        )
        let updated = try #require(
            PaneLayoutReducer.setPaneColor(in: session, paneID: innerRight.id, color: .palette(.green))
        )
        #expect(updated.layout.pane(id: innerRight.id)?.color == .palette(.green))
        #expect(updated.layout.pane(id: innerLeft.id)?.color == nil)
        #expect(updated.layout.pane(id: left.id)?.color == nil)
    }
}
