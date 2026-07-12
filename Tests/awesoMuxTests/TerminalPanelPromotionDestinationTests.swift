import Testing
import AwesoMuxCore
@testable import awesoMux

// Toggle-action cases moved to FloatingSlotBookTests when that logic was
// extracted; these promotion-destination cases stay with their owning type.
@Suite("Terminal panel promotion destination")
@MainActor
struct TerminalPanelPromotionDestinationTests {
    @Test("promotion returns the floating slot to its parent workgroup")
    func promotionUsesParentWorkgroup() {
        let parent = TerminalSession(title: "Parent", workingDirectory: "~")
        let groups = [
            SessionGroup(name: "Default", sessions: []),
            SessionGroup(name: "Client work", sessions: [parent])
        ]

        #expect(
            TerminalPanelController.promotionDestinationGroupName(
                for: parent.id,
                in: groups,
                fallback: "Default"
            ) == "Client work"
        )
    }

    @Test("promotion falls back to the default workgroup without a parent")
    func promotionUsesFallbackWithoutParent() {
        #expect(
            TerminalPanelController.promotionDestinationGroupName(
                for: TerminalSession.ID(),
                in: [],
                fallback: "Default"
            ) == "Default"
        )
    }

    // INT-799: a cancel that lands after the user switched away must settle the
    // data move but must NOT reselect the promoted terminal in the main store.
    @Test("cancel after a switch-away leaves the main store selection untouched")
    func cancelAfterSwitchAwayDoesNotOverwriteSelection() {
        let promoted = TerminalSession(title: "Promoted", workingDirectory: "~")
        let userChoice = TerminalSession(title: "User choice", workingDirectory: "~")
        let mainStore = SessionStore(groups: [
            SessionGroup(name: "Default", sessions: [userChoice])
        ])
        mainStore.selectedSessionID = userChoice.id

        let controller = TerminalPanelController(mode: .floating)
        let otherWorkspace = TerminalSession.ID()
        controller.seedInFlightPromotionTestSlot(
            workspaceID: promoted.id,
            session: promoted,
            mainStore: mainStore,
            activeWorkspaceID: otherWorkspace   // user switched away
        )

        controller.cancelPromotionForTesting()

        #expect(mainStore.selectedSessionID == userChoice.id)
    }

    // The complementary case: when the promotion still owns the visible panel,
    // cancellation DOES reselect it (the data move fully rolls forward).
    @Test("cancel while still owning the panel reselects the promoted session")
    func cancelWhileOwningReselectsPromoted() {
        let promoted = TerminalSession(title: "Promoted", workingDirectory: "~")
        let mainStore = SessionStore(groups: [
            SessionGroup(name: "Default", sessions: [promoted])
        ])
        mainStore.selectedSessionID = nil

        let controller = TerminalPanelController(mode: .floating)
        controller.seedInFlightPromotionTestSlot(
            workspaceID: promoted.id,
            session: promoted,
            mainStore: mainStore,
            activeWorkspaceID: promoted.id   // still owns the visible panel
        )

        controller.cancelPromotionForTesting()

        #expect(mainStore.selectedSessionID == promoted.id)
    }
}
