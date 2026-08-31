import AppKit
import AwesoMuxCore
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

    // MARK: - Authoritative route across the super handoff

    @Test("menu(for:) honors the pre-armed right-click route instead of recomputing")
    func armedRightClickRouteIsAuthoritative() {
        // Headless mount: no native surface spawns, so a recomputed route
        // would be .ignore (no menu). With the gesture pre-armed by
        // rightMouseDown, menu(for:) must return the menu anyway — capture
        // state can flip on another thread between the two reads, and a
        // disagreeing second read would swallow the gesture after the
        // release was already suppressed.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }

        let pane = TerminalPane(title: "terminal", workingDirectory: "/tmp", executionPlan: .local)
        let session = TerminalSession(
            title: "session",
            workingDirectory: "/tmp",
            layout: .pane(pane),
            activePaneID: pane.id
        )
        let store = SessionStore(
            groups: [SessionGroup(name: "awesoMux", sessions: [session])],
            selectedSessionID: session.id
        )
        let runtime = GhosttyRuntime()
        defer { runtime.discardAllSurfaces() }
        let view = runtime.surfaceView(
            sessionStore: store,
            session: session,
            pane: pane,
            enabledAgentRuntimeFileDropSources: [], grokIconEnabled: false
        )
        window.contentView?.addSubview(view)

        guard
            let event = NSEvent.mouseEvent(
                with: .rightMouseDown,
                location: NSPoint(x: 10, y: 10),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )
        else {
            Issue.record("could not synthesize a right-mouse-down event")
            return
        }

        // Unarmed, the headless (dead-surface) route shows no menu.
        #expect(view.menu(for: event) == nil)

        view.inputState.rightClickMenuRouteArmed = true
        defer { view.inputState.rightClickMenuRouteArmed = false }
        #expect(view.menu(for: event) != nil)
    }
}
