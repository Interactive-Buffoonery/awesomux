import AppKit
import Testing
@testable import awesoMux

@Suite("Menu bar mini-status item")
struct MenuBarMiniStatusItemControllerTests {
    @Test("disabled setting keeps the menu bar item hidden even during attention")
    func disabledSettingKeepsItemHidden() {
        #expect(!MenuBarMiniStatusPresentation.shouldShow(
            isEnabled: false,
            hasWorkspaceNeedingInput: true
        ))
    }

    @Test("enabled setting stays visually hidden while no workspace needs input")
    func enabledIdleStateStaysHidden() {
        #expect(!MenuBarMiniStatusPresentation.shouldShow(
            isEnabled: true,
            hasWorkspaceNeedingInput: false
        ))
    }

    @Test("enabled setting shows the item only while a workspace needs input")
    func enabledAttentionStateShowsItem() {
        #expect(MenuBarMiniStatusPresentation.shouldShow(
            isEnabled: true,
            hasWorkspaceNeedingInput: true
        ))
    }

    @Test("right mouse up opens the command menu")
    func rightMouseUpResolvesToSecondaryClick() {
        #expect(MenuBarMiniStatusClick.resolve(
            eventType: .rightMouseUp,
            modifierFlags: []
        ) == .secondary)
    }

    @Test("control click mirrors the secondary menu path")
    func controlClickResolvesToSecondaryClick() {
        #expect(MenuBarMiniStatusClick.resolve(
            eventType: .leftMouseUp,
            modifierFlags: .control
        ) == .secondary)
    }

    @Test("ordinary left click opens the floating panel")
    func leftMouseUpResolvesToPrimaryClick() {
        #expect(MenuBarMiniStatusClick.resolve(
            eventType: .leftMouseUp,
            modifierFlags: []
        ) == .primary)
    }
}
