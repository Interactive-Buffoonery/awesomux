import AppKit
import AwesoMuxConfig
import SwiftUI
import Testing

@testable import awesoMux

@Suite("First-run tour copy")
struct FirstRunTourCopyTests {
    /// Deliberately NOT the default binding. `newWorkspace`'s default
    /// `displaySymbol` is literally "⌘N", so an assertion against the default
    /// passes just as happily for a hard-coded chord as for an interpolated
    /// one — the exact regression this suite exists to catch.
    private static let rebound = KeyboardShortcutCatalog.newWorkspace
        .applying(ShortcutBindingConfig(key: "j", modifiers: [.command, .shift]))

    @Test("Beat copy renders the resolved chord, never a literal")
    func copyUsesResolvedBinding() {
        let copy = FirstRunTourCopy.workspacesBeat(newWorkspace: Self.rebound)
        #expect(copy.visible.contains(Self.rebound.displaySymbol))
        #expect(copy.spoken.contains(Self.rebound.spokenForm))
        #expect(copy.visible.contains("Command-N") == false)
        #expect(copy.visible.contains("⌘N") == false)
    }

    @Test("Companion beat renders both resolved chords")
    func companionBeatUsesResolvedBindings() {
        let panel = KeyboardShortcutCatalog.toggleFloatingPanel
            .applying(ShortcutBindingConfig(key: "j", modifiers: [.command, .option]))
        let companion = KeyboardShortcutCatalog.togglePopUpTerminal
            .applying(ShortcutBindingConfig(key: "y", modifiers: [.command, .control]))
        let copy = FirstRunTourCopy.companionBeat(
            floatingPanel: panel, popUpTerminal: companion)
        #expect(copy.visible.contains(panel.displaySymbol))
        #expect(copy.visible.contains(companion.displaySymbol))
        #expect(copy.spoken.contains(panel.spokenForm))
        #expect(copy.spoken.contains(companion.spokenForm))
        #expect(copy.visible.contains("⌘'") == false)
    }

    @Test("Elsewhere beat renders both resolved chords")
    func elsewhereBeatUsesResolvedBindings() {
        let palette = KeyboardShortcutCatalog.toggleCommandPalette
            .applying(ShortcutBindingConfig(key: "j", modifiers: [.command, .shift]))
        let cheatsheet = KeyboardShortcutCatalog.showKeyboardCheatsheet
            .applying(ShortcutBindingConfig(key: "y", modifiers: [.command, .option]))
        let copy = FirstRunTourCopy.elsewhereBeat(
            commandPalette: palette, keyboardCheatsheet: cheatsheet)
        #expect(copy.visible.contains(palette.displaySymbol))
        #expect(copy.visible.contains(cheatsheet.displaySymbol))
        #expect(copy.spoken.contains(palette.spokenForm))
        #expect(copy.spoken.contains(cheatsheet.spokenForm))
        #expect(copy.visible.contains("⌘K") == false)
    }

    @Test("Chordless beats speak exactly what they show")
    func chordlessBeatsMatch() {
        for copy in [FirstRunTourCopy.sidebarBeat(), FirstRunTourCopy.agentsBeat()] {
            #expect(copy.visible.isEmpty == false)
            #expect(copy.spoken == copy.visible)
        }
    }

    // `beatCount` is main-actor-isolated on the controller; the copy itself
    // is not, so only this one case needs the hop.
    @MainActor
    @Test("Every beat index resolves to a heading and body")
    func everyBeatHasCopy() {
        let shortcuts = FirstRunTourShortcuts(keyboard: .defaultValue)
        for beat in 0..<FirstRunTourController.beatCount {
            let page = FirstRunTourCopy.beat(beat, shortcuts: shortcuts)
            #expect(page.heading.isEmpty == false)
            #expect(page.body.visible.isEmpty == false)
            #expect(page.body.spoken.isEmpty == false)
        }
    }

    /// Guards the panel-sizing contract the controller depends on: the beats
    /// really do differ in height (so pinning to the tallest is what stops the
    /// window resizing under the user mid-tour), and measurement returns real
    /// numbers rather than silently collapsing to the controller's fallback.
    @MainActor
    @Test("Beats measure to real, differing heights")
    func beatsMeasureDifferently() {
        let shortcuts = FirstRunTourShortcuts(keyboard: .defaultValue)
        let heights = (0..<FirstRunTourController.beatCount).map { beat in
            NSHostingView(
                rootView: FirstRunTourPage(
                    beat: beat,
                    shortcuts: shortcuts,
                    onBack: {},
                    onNext: {},
                    onDismiss: {},
                    onOpenAgentSettings: {},
                    onDiscoverFeatures: {})
            ).fittingSize.height
        }
        #expect(heights.allSatisfy { $0 > 0 })
        #expect((heights.max() ?? 0) > (heights.min() ?? 0))
    }
}
