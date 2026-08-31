import AppKit
import AwesoMuxConfig
import AwesoMuxCore
import Testing
@testable import awesoMux

@Suite("Menu bar mini-status item")
struct MenuBarMiniStatusItemControllerTests {
    @Test("never keeps the menu bar item hidden even during attention")
    func neverKeepsItemHidden() {
        #expect(!MenuBarMiniStatusPresentation.shouldShow(
                visibility: .never,
            hasWorkspaceNeedingInput: true
        ))
    }

    @Test("needs input stays hidden while no workspace needs input")
    func needsInputIdleStateStaysHidden() {
        #expect(!MenuBarMiniStatusPresentation.shouldShow(
                visibility: .needsInput,
            hasWorkspaceNeedingInput: false
        ))
    }

    @Test("needs input shows the item while a workspace needs input")
    func needsInputAttentionStateShowsItem() {
        #expect(MenuBarMiniStatusPresentation.shouldShow(
                visibility: .needsInput,
            hasWorkspaceNeedingInput: true
        ))
    }

    @Test("always shows the item while workspaces are idle")
    func alwaysShowsIdleItem() {
        #expect(
            MenuBarMiniStatusPresentation.shouldShow(
                visibility: .always,
                hasWorkspaceNeedingInput: false
            ))
    }

    @MainActor
    @Test("menu bar uses the shared awesoMux smile")
    func menuBarUsesSharedSmile() {
        #expect(MenuBarMiniStatusItemController.statusTitle == Brandmark.glyph)
    }

    @MainActor
    @Test("a workspace needing acknowledgement requests the menu bar badge")
    func needsAcknowledgementRequestsBadge() {
        let pane = TerminalPane(
            title: "codex",
            workingDirectory: "~",
            agentKind: .codex,
            attentionReason: .permissionPrompt,
            executionPlan: .local
        )
        let session = TerminalSession(
            title: "codex",
            workingDirectory: "~",
            layout: .pane(pane),
            activePaneID: pane.id
        )
        let store = SessionStore(groups: [SessionGroup(name: "agents", sessions: [session])])

        #expect(session.needsAcknowledgement)
        #expect(store.hasWorkspaceNeedingInputForMenuBar)
    }

    @MainActor
    @Test("unread workspace activity alone does not request the menu bar badge")
    func unreadActivityDoesNotRequestBadge() {
        let pane = TerminalPane(
            title: "claude",
            workingDirectory: "~",
            agentKind: .claudeCode,
            unreadNotificationCount: 1,
            executionPlan: .local
        )
        let session = TerminalSession(
            title: "claude",
            workingDirectory: "~",
            layout: .pane(pane),
            activePaneID: pane.id
        )
        let store = SessionStore(groups: [SessionGroup(name: "agents", sessions: [session])])

        #expect(!session.needsAcknowledgement)
        #expect(!store.hasWorkspaceNeedingInputForMenuBar)
    }

    @MainActor
    @Test("an unanswered turn requests the menu bar badge")
    func unansweredTurnRequestsBadge() {
        let pane = TerminalPane(
            title: "claude",
            workingDirectory: "~",
            agentKind: .claudeCode,
            executionPlan: .local
        )
        let session = TerminalSession(
            title: "claude",
            workingDirectory: "~",
            layout: .pane(pane),
            activePaneID: pane.id
        )
        let store = SessionStore(groups: [SessionGroup(name: "agents", sessions: [session])])

        #expect(!session.needsAcknowledgement)
        #expect(session.unreadNotificationCount == 0)
        #expect(
            SessionStore.hasWorkspaceNeedingInputForMenuBar(
                groups: store.groups,
                unansweredTurnPaneIDs: [pane.id]
            ))
    }

    @MainActor
    @Test("menu bar item meets the minimum pointer target width")
    func menuBarItemMeetsMinimumPointerTargetWidth() {
        #expect(MenuBarMiniStatusItemController.statusItemLength >= 24)
    }
}
