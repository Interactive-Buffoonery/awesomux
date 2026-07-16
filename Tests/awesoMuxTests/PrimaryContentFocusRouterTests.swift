import AppKit
import AwesoMuxCore
import SwiftUI
import Testing
@testable import awesoMux

@Suite("Primary content focus router", .serialized)
@MainActor
struct PrimaryContentFocusRouterTests {
    struct ReconnectFocusCase: Sendable, CustomTestStringConvertible {
        let name: String
        let requiresKeyboardFocus: Bool
        let requiresAccessibilityFocus: Bool

        var testDescription: String { name }
    }

    private final class ReadinessWindow: NSWindow {
        var reportsKey = false
        override var isKeyWindow: Bool { reportsKey }
    }

    private final class FirstResponderView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    @Test("no selected session routes keyboard and accessibility focus to real empty action")
    func noSelectedSessionRoutesToRealEmptyAction() async throws {
        let application = NSApplication.shared
        let sessionStore = SessionStore(groups: [])
        let initialFocusRequest = EmptyWorkspaceInitialAccessibilityFocusRequest(
            applicationIsActive: { false })
        let detail = NSHostingController(
            rootView: EmptyWorkspaceView(
                mode: .firstLaunch,
                onNewWorkspace: {},
                onOpenRecent: {},
                canReopenWorkspace: false,
                initialAccessibilityFocusRequest: initialFocusRequest))
        let frame = CGRect(x: 0, y: 0, width: 720, height: 480)
        let window = ReadinessWindow(
            contentRect: frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        let contentView = NSView(frame: frame)
        window.contentView = contentView
        detail.view.frame = contentView.bounds
        detail.view.autoresizingMask = [.width, .height]
        contentView.addSubview(detail.view)
        window.awesoMuxWindowRole = .primaryContent
        window.alphaValue = 0
        window.reportsKey = true
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        defer {
            window.awesoMuxWindowRole = nil
            window.orderOut(nil)
        }

        #expect(
            await waitUntil {
                window.layoutIfNeeded()
                detail.view.layoutSubtreeIfNeeded()
                return EmptyWorkspaceAccessibilityFocusHandoff.target(in: contentView) != nil
            })
        let target = try #require(
            EmptyWorkspaceAccessibilityFocusHandoff.target(in: contentView))
        let targetView = try #require(target as? NSView)
        #expect(sessionStore.selectedSession == nil)
        #expect(!target.isAccessibilityFocused())

        let outcome = PrimaryContentFocusRouter.focus(
            SidebarFocusHandoffRequest(
                requiresKeyboardFocus: true,
                requiresAccessibilityFocus: true),
            sessionStore: sessionStore,
            application: application,
            primaryContentWindow: { _ in window },
            applicationIsActive: { true })

        #expect(outcome?.destination === targetView)
        #expect(outcome?.keyboardFocusSucceeded == true)
        #expect(outcome?.accessibilityFocusSucceeded == true)
        #expect(window.firstResponder === targetView)
        #expect(target.isAccessibilityFocused())
    }

    @Test("non-key primary does not move keyboard or accessibility focus")
    func nonKeyPrimaryDoesNotReceiveFocus() throws {
        let application = NSApplication.shared
        let sessionStore = SessionStore(groups: [])
        let frame = CGRect(x: 0, y: 0, width: 720, height: 480)
        let contentView = NSView(frame: frame)
        let sentinel = FirstResponderView(
            frame: CGRect(x: 20, y: 20, width: 80, height: 24))
        let target = EmptyWorkspacePrimaryActionFocusButton()
        target.frame = CGRect(x: 20, y: 60, width: 160, height: 32)
        contentView.addSubview(sentinel)
        contentView.addSubview(target)
        let window = ReadinessWindow(
            contentRect: frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        window.contentView = contentView
        window.awesoMuxWindowRole = .primaryContent
        window.alphaValue = 0
        window.orderFrontRegardless()
        defer {
            window.awesoMuxWindowRole = nil
            window.orderOut(nil)
        }
        #expect(window.isVisible)
        #expect(!window.isKeyWindow)
        #expect(window.makeFirstResponder(sentinel))

        #expect(
            PrimaryContentFocusRouter.focus(
                SidebarFocusHandoffRequest(
                    requiresKeyboardFocus: true,
                    requiresAccessibilityFocus: true),
                sessionStore: sessionStore,
                application: application,
                primaryContentWindow: { _ in window },
                applicationIsActive: { true }) == nil)

        #expect(window.firstResponder === sentinel)
        #expect(!target.isAccessibilityFocused())
    }

    @Test(
        "reconnect-covered selected surface rejects focus until reconnect clears",
        arguments: [
            ReconnectFocusCase(
                name: "keyboard only",
                requiresKeyboardFocus: true,
                requiresAccessibilityFocus: false),
            ReconnectFocusCase(
                name: "accessibility only",
                requiresKeyboardFocus: false,
                requiresAccessibilityFocus: true),
            ReconnectFocusCase(
                name: "keyboard and accessibility",
                requiresKeyboardFocus: true,
                requiresAccessibilityFocus: true),
        ])
    func reconnectCoveredSelectedSurfaceRejectsFocus(
        testCase: ReconnectFocusCase
    ) throws {
        let target = try #require(RemoteTarget(user: "deploy", host: "prod.example"))
        var pane = TerminalPane(
            title: "remote",
            workingDirectory: "/home/deploy",
            executionPlan: .ssh(SSHExecution(target: target)))
        pane.remoteReconnect = .disconnected(.init(target: target))
        let session = TerminalSession(
            title: "remote",
            workingDirectory: pane.workingDirectory,
            layout: .pane(pane),
            activePaneID: pane.id)
        let sessionStore = SessionStore(
            groups: [SessionGroup(name: "remote", sessions: [session])],
            selectedSessionID: session.id)
        let runtime = GhosttyRuntime()
        let surface = runtime.surfaceView(
            sessionStore: sessionStore,
            session: session,
            pane: pane,
            enabledAgentRuntimeFileDropSources: [],
            grokIconEnabled: false)
        surface.update(
            sessionStore: sessionStore,
            session: session,
            pane: pane,
            enabledAgentRuntimeFileDropSources: [],
            grokIconEnabled: false)
        let frame = CGRect(x: 0, y: 0, width: 720, height: 480)
        let root = NSView(frame: frame)
        let sentinel = FirstResponderView(
            frame: CGRect(x: 20, y: 20, width: 120, height: 24))
        root.addSubview(sentinel)
        let container = GhosttySurfaceContainerView(
            contentSize: CGSize(width: 520, height: 360))
        container.frame = CGRect(x: 160, y: 40, width: 520, height: 360)
        root.addSubview(container)
        container.mount(surface, isActive: false, contentSize: container.bounds.size)
        let window = ReadinessWindow(
            contentRect: frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        window.contentView = root
        window.awesoMuxWindowRole = .primaryContent
        window.alphaValue = 0
        window.reportsKey = true
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        defer {
            window.awesoMuxWindowRole = nil
            window.orderOut(nil)
            runtime.discardAllSurfaces()
        }
        #expect(window.makeFirstResponder(sentinel))
        #expect(!surface.isAccessibilityElement())
        surface.setAccessibilityFocused(true)
        #expect(!surface.isAccessibilityFocused())
        #expect(!runtime.isSecureInputFocusedForTesting(pane.id))
        let request = SidebarFocusHandoffRequest(
            requiresKeyboardFocus: testCase.requiresKeyboardFocus,
            requiresAccessibilityFocus: testCase.requiresAccessibilityFocus)

        #expect(
            PrimaryContentFocusRouter.focus(
                request,
                sessionStore: sessionStore,
                application: .shared,
                primaryContentWindow: { _ in window },
                applicationIsActive: { true }) == nil)

        #expect(window.firstResponder === sentinel)
        #expect(!surface.isAccessibilityFocused())
        #expect(!runtime.isSecureInputFocusedForTesting(pane.id))

        #expect(
            sessionStore.confirmPaneRemoteReconnected(
                sessionID: session.id,
                paneID: pane.id))
        let reconnectedSession = try #require(sessionStore.selectedSession)
        let reconnectedPane = try #require(reconnectedSession.activePane)
        surface.update(
            sessionStore: sessionStore,
            session: reconnectedSession,
            pane: reconnectedPane,
            enabledAgentRuntimeFileDropSources: [],
            grokIconEnabled: false)
        #expect(surface.isAccessibilityElement())
        let outcome = PrimaryContentFocusRouter.focus(
            request,
            sessionStore: sessionStore,
            application: .shared,
            primaryContentWindow: { _ in window },
            applicationIsActive: { true })
        #expect(outcome?.destination === surface)
        #expect(outcome?.keyboardFocusSucceeded == testCase.requiresKeyboardFocus)
        #expect(
            outcome?.accessibilityFocusSucceeded
                == testCase.requiresAccessibilityFocus)

        surface.setAccessibilityFocused(true)
        #expect(surface.isAccessibilityFocused())
        var coveredPane = reconnectedPane
        coveredPane.remoteReconnect = .disconnected(.init(target: target))
        surface.update(
            sessionStore: sessionStore,
            session: reconnectedSession,
            pane: coveredPane,
            enabledAgentRuntimeFileDropSources: [],
            grokIconEnabled: false)
        #expect(!surface.isAccessibilityElement())
        #expect(!surface.isAccessibilityFocused())
    }

    private func waitUntil(
        _ condition: () -> Bool,
        attempts: Int = 100
    ) async -> Bool {
        for _ in 0..<attempts {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }
}
