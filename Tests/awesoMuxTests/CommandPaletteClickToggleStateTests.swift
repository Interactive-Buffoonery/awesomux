import AppKit
import Testing
@testable import awesoMux

@Suite("Command palette click toggle state")
struct CommandPaletteClickToggleStateTests {
    @Test("suppresses the mouse-up toggle after mouse-down resign dismissal")
    func suppressesMatchingMouseUpToggle() {
        var state = CommandPaletteClickToggleState()

        let recordedDismiss = state.recordResignDismiss(during: .leftMouseDown)
        #expect(recordedDismiss)
        #expect(state.isPendingMouseUp(.leftMouseUp))
        let suppressedToggle = state.consumeToggle(during: .leftMouseUp)
        #expect(suppressedToggle)
        let suppressedSecondToggle = state.consumeToggle(during: .leftMouseUp)
        #expect(!suppressedSecondToggle)
    }

    @Test("preserves keyboard and menu toggles")
    func preservesNonmatchingToggles() {
        var keyboardState = CommandPaletteClickToggleState()
        let recordedKeyboardDismiss = keyboardState.recordResignDismiss(during: .keyDown)
        #expect(!recordedKeyboardDismiss)
        let suppressedKeyboardToggle = keyboardState.consumeToggle(during: .keyDown)
        #expect(!suppressedKeyboardToggle)

        var menuState = CommandPaletteClickToggleState()
        let suppressedMenuToggle = menuState.consumeToggle(during: .leftMouseUp)
        #expect(!suppressedMenuToggle)
    }

    @Test("expires suppression after a mouse-up without a toggle")
    func expiresAfterMouseUpDispatch() {
        var state = CommandPaletteClickToggleState()

        let recordedDismiss = state.recordResignDismiss(during: .leftMouseDown)
        #expect(recordedDismiss)
        state.finishMouseUpDispatch()

        let suppressedToggle = state.consumeToggle(during: .leftMouseUp)
        #expect(!suppressedToggle)
    }

    @Test("matches each mouse button to its own release")
    func matchesMouseButton() {
        var state = CommandPaletteClickToggleState()

        let recordedDismiss = state.recordResignDismiss(during: .rightMouseDown)
        #expect(recordedDismiss)
        #expect(!state.isPendingMouseUp(.leftMouseUp))
        #expect(state.isPendingMouseUp(.rightMouseUp))
        let suppressedToggle = state.consumeToggle(during: .rightMouseUp)
        #expect(suppressedToggle)
    }
}
