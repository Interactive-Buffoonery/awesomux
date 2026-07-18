import AwesoMuxCore
import SwiftUI
import Testing
@testable import awesoMux

@Suite("Sidebar search interaction")
@MainActor
struct SidebarSearchInteractionTests {
    @Test("only unmodified arrow presses navigate search results")
    func onlyUnmodifiedArrowsNavigate() {
        #expect(SidebarSearchKeyPressPolicy.acceptsNavigation(modifiers: []))
        #expect(!SidebarSearchKeyPressPolicy.acceptsNavigation(modifiers: .option))
        #expect(!SidebarSearchKeyPressPolicy.acceptsNavigation(modifiers: .command))
        #expect(!SidebarSearchKeyPressPolicy.acceptsNavigation(modifiers: .control))
        #expect(!SidebarSearchKeyPressPolicy.acceptsNavigation(modifiers: .shift))
        #expect(
            !SidebarSearchKeyPressPolicy.acceptsNavigation(
                modifiers: [.option, .shift]
            )
        )
    }

    @Test("selection resolves a current live session")
    func selectionResolvesLiveSession() {
        let live = TerminalSession(title: "Live", workingDirectory: "/tmp/live")
        let top = TerminalSession(title: "Top", workingDirectory: "/tmp/top")
        let store = SessionStore(groups: [
            SessionGroup(name: "Work", sessions: [live, top])
        ])

        #expect(
            SidebarSearchSelectionResolver.liveSession(
                focusedID: live.id,
                topMatchID: top.id,
                in: store
            )?.id == live.id
        )
        #expect(
            SidebarSearchSelectionResolver.liveSession(
                focusedID: nil,
                topMatchID: top.id,
                in: store
            )?.id == top.id
        )
    }

    @Test("selection safely rejects a stale focused result")
    func selectionRejectsStaleResult() {
        let live = TerminalSession(title: "Live", workingDirectory: "/tmp/live")
        let store = SessionStore(groups: [
            SessionGroup(name: "Work", sessions: [live])
        ])

        #expect(
            SidebarSearchSelectionResolver.liveSession(
                focusedID: TerminalSession.ID(),
                topMatchID: live.id,
                in: store
            ) == nil
        )
        #expect(
            SidebarSearchSelectionResolver.liveSession(
                focusedID: nil,
                topMatchID: nil,
                in: store
            ) == nil
        )
    }
}
