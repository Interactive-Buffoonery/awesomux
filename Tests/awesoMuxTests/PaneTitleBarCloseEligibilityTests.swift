import AppKit
import AwesoMuxCore
import SwiftUI
import Testing
@testable import awesoMux

@MainActor
struct PaneTitleBarCloseEligibilityTests {
    @Test("retained title bars invalidate when terminal close eligibility changes")
    func terminalMultiplicityInvalidatesTitleBar() {
        let first = TerminalPane(title: "Unchanged", workingDirectory: "~", executionPlan: .local)
        let second = TerminalPane(title: "Second", workingDirectory: "~", executionPlan: .local)
        let session = TerminalSession(
            title: "Workspace", workingDirectory: "~",
            layout: .split(TerminalSplit(orientation: .vertical, first: .pane(first), second: .pane(second))),
            activePaneID: first.id)
        var singleTerminal = session
        singleTerminal.layout = .pane(first)
        let store = SessionStore(groups: [SessionGroup(name: "Fixture", sessions: [session])])
        let runtime = GhosttyRuntime()
        defer { runtime.discardAllSurfaces() }
        let before = PaneTitleBarView(
            session: session, pane: first, sessionStore: store,
            dragCoordinator: runtime.paneDragCoordinator, runtime: runtime, reduceTransparency: false)
        let after = PaneTitleBarView(
            session: singleTerminal, pane: first, sessionStore: store,
            dragCoordinator: runtime.paneDragCoordinator, runtime: runtime, reduceTransparency: false)
        #expect(before != after)
        #expect(after != before)
        #expect(before == before)
    }

    @Test("a retained close action cannot close the final terminal workspace")
    func staleCloseActionPreservesWorkspace() throws {
        let first = TerminalPane(title: "First", workingDirectory: "~", executionPlan: .local)
        let second = TerminalPane(title: "Second", workingDirectory: "~", executionPlan: .local)
        let session = TerminalSession(
            title: "Workspace", workingDirectory: "~",
            layout: .split(TerminalSplit(orientation: .vertical, first: .pane(first), second: .pane(second))),
            activePaneID: first.id)
        let store = SessionStore(groups: [SessionGroup(name: "Fixture", sessions: [session])])
        let runtime = GhosttyRuntime()
        defer { runtime.discardAllSurfaces() }
        let host = NSHostingView(
            rootView: PaneTitleBarView(
                session: session, pane: first, sessionStore: store,
                dragCoordinator: runtime.paneDragCoordinator, runtime: runtime, reduceTransparency: false))
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 24)
        host.layoutSubtreeIfNeeded()
        func closeButton(in view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.accessibilityLabel() == "Close pane" { return button }
            return view.subviews.lazy.compactMap { closeButton(in: $0) }.first
        }
        let button = try #require(closeButton(in: host))
        _ = store.closePane(id: second.id, in: session.id)
        button.performClick(nil)
        #expect(store.session(id: session.id)?.activePaneID == first.id)
    }
}
