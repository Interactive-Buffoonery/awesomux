import AppKit
import SwiftUI
import Testing
@testable import awesoMux

/// `PaneCloseButton` is the shared close affordance for both the terminal pane
/// title bar and the document pane title bar. Its whole reason to exist over a
/// SwiftUI `Button` is that it does NOT steal first responder on click: closing
/// one side of a split collapses onto the surviving terminal, whose cached
/// libghostty surface only reclaims keyboard focus when the window's first
/// responder is vacant. A button that grabbed first responder would leave a
/// non-vacant responder at collapse time and the survivor would read as a
/// blanked terminal (INT-562 PR1). These guard that invariant so a future
/// refactor can't silently regress to a focus-stealing button.
@MainActor
@Suite
struct PaneCloseButtonTests {
    @Test
    func refusesFirstResponderSoCollapsePreservesSurvivorFocus() {
        let button = PaneCloseButton.makeButton(
            tint: .primary,
            accessibilityLabel: "Close pane",
            target: PaneCloseButton.Coordinator(action: {})
        )
        #expect(button.refusesFirstResponder)
    }

    @Test
    func firesActionThroughCoordinatorTargetAction() {
        var fired = false
        let coordinator = PaneCloseButton.Coordinator(action: { fired = true })
        let button = PaneCloseButton.makeButton(
            tint: .primary,
            accessibilityLabel: "Close pane",
            target: coordinator
        )
        // Drive the AppKit target/action exactly as a click would.
        _ = button.target?.perform(button.action, with: button)
        #expect(fired)
    }

    @Test
    func usesProvidedAccessibilityLabel() {
        let button = PaneCloseButton.makeButton(
            tint: .primary,
            accessibilityLabel: "Close document NOTES.md",
            target: PaneCloseButton.Coordinator(action: {})
        )
        #expect(button.accessibilityLabel() == "Close document NOTES.md")
    }
}
