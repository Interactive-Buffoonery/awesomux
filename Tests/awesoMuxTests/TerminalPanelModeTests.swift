import CoreGraphics
import Testing
import AwesoMuxCore
@testable import awesoMux

@Suite("Terminal panel mode config")
struct TerminalPanelModeTests {
    // ADR-0030 is load-bearing: the companion NEVER intercepts bare Escape (TUIs
    // keep it); the floating panel keeps Escape smart-dismiss. Guard both.
    @Test("companion mode never intercepts bare Escape")
    func companionKeepsEscape() {
        #expect(TerminalPanelMode.companion.interceptsBareEscape == false)
    }

    @Test("floating mode intercepts bare Escape for smart dismiss")
    func floatingInterceptsEscape() {
        #expect(TerminalPanelMode.floating.interceptsBareEscape == true)
    }

    @Test("companion anchors bottom-trailing with a corner tab and app-wide persistence")
    func companionShape() {
        #expect(TerminalPanelMode.companion.anchor == .bottomTrailing)
        #expect(TerminalPanelMode.companion.hasCornerTab == true)
        #expect(TerminalPanelMode.companion.persistsAcrossWorkspaces == true)
    }

    @Test("floating anchors center, has no corner tab, is per-workspace")
    func floatingShape() {
        #expect(TerminalPanelMode.floating.anchor == .center)
        #expect(TerminalPanelMode.floating.hasCornerTab == false)
        #expect(TerminalPanelMode.floating.persistsAcrossWorkspaces == false)
    }

    @Test("each mode carries its own default and minimum size")
    func modeSizes() {
        #expect(TerminalPanelMode.companion.defaultSize == PopUpTerminalLayout.defaultExpandedSize)
        #expect(TerminalPanelMode.companion.minimumSize == PopUpTerminalLayout.minimumExpandedSize)
        #expect(TerminalPanelMode.floating.defaultSize == FloatingPanelLayout.defaultSize)
        #expect(TerminalPanelMode.floating.minimumSize == FloatingPanelLayout.minimumSize)
    }
}
