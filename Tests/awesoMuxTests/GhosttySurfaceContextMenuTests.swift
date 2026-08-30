import AppKit
import Testing
@testable import awesoMux

/// Covers the terminal surface context menu's routing policy and the menu's
/// static structure.
///
/// What these deliberately do NOT claim: live item enablement. Headless
/// `NSMenu.update()` never calls custom validation and no `NSApplication`
/// event loop runs here (probed live, INT-197 — see the fixtures comment in
/// `GhosttySurfaceEditActionValidationTests.swift:137-143`). Enablement is
/// covered by `GhosttySurfaceEditActionValidationTests`' truth table plus
/// live-app verification; these tests prove structure and policy only.
@MainActor
@Suite("GhosttySurface context menu")
struct GhosttySurfaceContextMenuTests {
    // MARK: - Right-click routing

    @Test("right-click presents the menu only on a live, uncaptured surface")
    func rightClickRouteTruthTable() {
        #expect(
            GhosttySurfaceContextMenuPolicy.rightClickRoute(
                hasSurface: true, mouseCaptured: false
            ) == .presentMenu)
        // A mouse-mode TUI (vim, htop, tmux) asked for the right button.
        #expect(
            GhosttySurfaceContextMenuPolicy.rightClickRoute(
                hasSurface: true, mouseCaptured: true
            ) == .forwardToTerminal)
        // Dead pane: no menu, and nothing to forward to.
        #expect(
            GhosttySurfaceContextMenuPolicy.rightClickRoute(
                hasSurface: false, mouseCaptured: false
            ) == .ignore)
        #expect(
            GhosttySurfaceContextMenuPolicy.rightClickRoute(
                hasSurface: false, mouseCaptured: true
            ) == .ignore)
    }

    // MARK: - ctrl+left routing

    @Test("ctrl+left shows the menu only with the modifier, live, and uncaptured")
    func ctrlLeftRouteTruthTable() {
        #expect(
            GhosttySurfaceContextMenuPolicy.ctrlLeftRoute(
                hasControlModifier: true, hasSurface: true, mouseCaptured: false
            ) == .showMenu)
        #expect(
            GhosttySurfaceContextMenuPolicy.ctrlLeftRoute(
                hasControlModifier: true, hasSurface: true, mouseCaptured: true
            ) == .suppressMenu)

        // No modifier, or no surface: AppKit's default applies either way.
        for mouseCaptured in [true, false] {
            #expect(
                GhosttySurfaceContextMenuPolicy.ctrlLeftRoute(
                    hasControlModifier: false, hasSurface: true, mouseCaptured: mouseCaptured
                ) == .deferToSuper)
            #expect(
                GhosttySurfaceContextMenuPolicy.ctrlLeftRoute(
                    hasControlModifier: true, hasSurface: false, mouseCaptured: mouseCaptured
                ) == .deferToSuper)
            #expect(
                GhosttySurfaceContextMenuPolicy.ctrlLeftRoute(
                    hasControlModifier: false, hasSurface: false, mouseCaptured: mouseCaptured
                ) == .deferToSuper)
        }
    }

    // MARK: - Menu structure

    @Test("menu items are nil-target actions in order, with no key equivalents")
    func menuShape() {
        let menu = GhosttySurfaceNSView.makeContextMenu()

        #expect(!menu.title.isEmpty)

        let expected: [Selector?] = [
            #selector(GhosttySurfaceNSView.copy(_:)),
            #selector(GhosttySurfaceNSView.paste(_:)),
            #selector(GhosttySurfaceNSView.selectAll(_:)),
            nil,
            #selector(GhosttySurfaceNSView.selectionForFind(_:)),
        ]
        #expect(menu.items.count == expected.count)
        guard menu.items.count == expected.count else { return }

        for (item, action) in zip(menu.items, expected) {
            #expect(item.action == action)
            // nil target routes through the responder chain to the focused
            // surface, exactly as the Edit menu does.
            #expect(item.target == nil)
            #expect(item.keyEquivalent.isEmpty)
            #expect(item.isSeparatorItem == (action == nil))
            if action != nil {
                #expect(!item.title.isEmpty)
            }
        }
    }

    @Test("menu autoenables so items resolve through the shared edit-action validator")
    func menuAutoenables() {
        #expect(GhosttySurfaceNSView.makeContextMenu().autoenablesItems)
    }
}
