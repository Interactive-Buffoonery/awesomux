import AppKit
import AwesoMuxCore
import Testing
@testable import awesoMux

/// INT-197: Cmd-A/C/V route through the Edit menu (`NSApp.mainMenu?
/// .performKeyEquivalent` in `GhosttySurfaceNSView.performKeyEquivalent`)
/// gated by `validateUserInterfaceItem`, replacing the old manual keyCode
/// dispatch. These tests cover the pure validation truth table and the
/// view-level wiring.
///
/// What they deliberately do NOT claim: the AppKit menu enablement/dispatch
/// contract (see the fixtures comment below), live menu routing to a real
/// surface, non-Latin-layout key-equivalent matching, or the VoiceOver
/// announcement — those are runtime platform behavior and stay on the manual
/// GUI smoke list.
@MainActor
@Suite("GhosttySurface edit action validation")
struct GhosttySurfaceEditActionValidationTests {
    // MARK: - Pure truth table

    private let editSelectors: [Selector] = [
        #selector(GhosttySurfaceNSView.copy(_:)),
        #selector(GhosttySurfaceNSView.paste(_:)),
        #selector(GhosttySurfaceNSView.selectAll(_:)),
        #selector(GhosttySurfaceNSView.pasteAsPlainText(_:)),
        #selector(GhosttySurfaceNSView.pasteSelection(_:)),
        #selector(GhosttySurfaceNSView.selectionForFind(_:)),
    ]

    @Test("gated actions enable only with a live surface AND first responder")
    func gatedActionsRequireSurfaceAndFirstResponder() {
        for action in editSelectors {
            #expect(GhosttySurfaceNSView.terminalEditActionValidation(
                action: action, hasSurface: true, isFirstResponder: true
            ) == true)
            #expect(GhosttySurfaceNSView.terminalEditActionValidation(
                action: action, hasSurface: false, isFirstResponder: true
            ) == false)
            #expect(GhosttySurfaceNSView.terminalEditActionValidation(
                action: action, hasSurface: true, isFirstResponder: false
            ) == false)
            #expect(GhosttySurfaceNSView.terminalEditActionValidation(
                action: action, hasSurface: false, isFirstResponder: false
            ) == false)
        }
    }

    @Test("non-gated actions defer regardless of surface/responder state")
    func nonGatedActionsDefer() {
        let deferred: [Selector?] = [
            #selector(NSText.cut(_:)),
            #selector(NSResponder.performTextFinderAction(_:)),
            nil,
        ]
        for action in deferred {
            for hasSurface in [true, false] {
                for isFirstResponder in [true, false] {
                    #expect(GhosttySurfaceNSView.terminalEditActionValidation(
                        action: action,
                        hasSurface: hasSurface,
                        isFirstResponder: isFirstResponder
                    ) == nil)
                }
            }
        }
    }

    @Test("key-up releases require a live first-responder surface")
    func keyUpReleaseRequiresLiveFirstResponderSurface() {
        #expect(GhosttySurfaceNSView.terminalKeyUpDispatchValidation(
            hasSurface: true, isFirstResponder: true
        ))
        #expect(!GhosttySurfaceNSView.terminalKeyUpDispatchValidation(
            hasSurface: false, isFirstResponder: true
        ))
        #expect(!GhosttySurfaceNSView.terminalKeyUpDispatchValidation(
            hasSurface: true, isFirstResponder: false
        ))
        #expect(!GhosttySurfaceNSView.terminalKeyUpDispatchValidation(
            hasSurface: false, isFirstResponder: false
        ))
    }

    // MARK: - View-level wiring

    @Test("headless view (no surface) disables gated actions, auto-enables the rest")
    func viewLevelValidationWiring() {
        let fixture = makePaneFixture()
        let window = makeWindow()
        defer { window.close() }
        let runtime = GhosttyRuntime()
        defer { runtime.discardAllSurfaces() }
        let view = runtime.surfaceView(
            sessionStore: fixture.store,
            session: fixture.session,
            pane: fixture.pane,
            enabledAgentRuntimeFileDropSources: [], grokIconEnabled: false
        )
        window.contentView?.addSubview(view)
        window.makeFirstResponder(view)
        #expect(window.firstResponder === view)

        // Headless mount: no native surface spawns, so the gated actions are
        // disabled even as first responder...
        for action in editSelectors {
            #expect(!view.validateUserInterfaceItem(StubValidatedItem(action: action)))
        }
        // ...while non-gated actions keep AppKit's auto-enable default.
        #expect(view.validateUserInterfaceItem(
            StubValidatedItem(action: #selector(NSResponder.performTextFinderAction(_:)))
        ))
    }

    // MARK: - Fixtures

    // The AppKit routing contract itself (menu enablement consulting
    // validateUserInterfaceItem, key-equivalent dispatch to the validated
    // target) is NOT unit-tested here: headless NSMenu.update() never calls
    // custom validation and performKeyEquivalent never delivers the action
    // without a running NSApplication event loop (probed live, INT-197).
    // That contract is covered by live-app verification and the manual GUI
    // smoke list instead.

    // NSValidatedUserInterfaceItem is an @objc protocol, so the stub must be
    // a class.
    private final class StubValidatedItem: NSObject, NSValidatedUserInterfaceItem {
        let action: Selector?
        let tag: Int = 0

        init(action: Selector?) {
            self.action = action
        }
    }

    private func makeWindow() -> NSWindow {
        // Never ordered front: mounting stays occlusion-invisible, so no
        // native libghostty surface (or shell) spawns, while the responder
        // chain behaves like the real window's.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }

    private struct PaneFixture {
        let session: TerminalSession
        let pane: TerminalPane
        let store: SessionStore
    }

    private func makePaneFixture() -> PaneFixture {
        let pane = TerminalPane(title: "terminal", workingDirectory: "/tmp")
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
        return PaneFixture(session: session, pane: pane, store: store)
    }
}
