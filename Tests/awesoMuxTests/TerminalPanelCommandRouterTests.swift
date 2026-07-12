import Testing
@testable import awesoMux

@Suite("Terminal panel command router")
struct TerminalPanelCommandRouterTests {
    @Test("key panel wins close routing")
    func keyPanelWins() {
        #expect(TerminalPanelCommandRouter.target(
            popUpIsKey: true,
            floatingIsKey: false,
            popUpIsVisible: true,
            floatingIsVisible: true,
            popUpOrder: 1,
            floatingOrder: 0
        ) == .popUp)
        #expect(TerminalPanelCommandRouter.target(
            popUpIsKey: false,
            floatingIsKey: true,
            popUpIsVisible: true,
            floatingIsVisible: true,
            popUpOrder: 0,
            floatingOrder: 1
        ) == .floating)
    }

    @Test("frontmost visible panel wins when neither is key")
    func frontmostVisibleWins() {
        #expect(TerminalPanelCommandRouter.target(
            popUpIsKey: false,
            floatingIsKey: false,
            popUpIsVisible: true,
            floatingIsVisible: true,
            popUpOrder: 0,
            floatingOrder: 1
        ) == .popUp)
    }

    @Test("a minimized pop-up yields close to the workspace pane")
    func minimizedPopUpYieldsClose() {
        // The caller passes isExpanded, so a minimized companion arrives as
        // not-visible and Cmd-W falls through to close the focused pane.
        #expect(TerminalPanelCommandRouter.target(
            popUpIsKey: false,
            floatingIsKey: false,
            popUpIsVisible: false,
            floatingIsVisible: false,
            popUpOrder: nil,
            floatingOrder: nil
        ) == .none)
    }

    @Test("no visible terminal panel falls through")
    func noPanelFallsThrough() {
        #expect(TerminalPanelCommandRouter.target(
            popUpIsKey: false,
            floatingIsKey: false,
            popUpIsVisible: false,
            floatingIsVisible: false,
            popUpOrder: nil,
            floatingOrder: nil
        ) == .none)
    }
}
