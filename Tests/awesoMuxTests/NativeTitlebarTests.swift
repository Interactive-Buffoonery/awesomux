import AppKit
import AwesoMuxConfig
import AwesoMuxCore
import AwesoMuxTestSupport
import SwiftUI
import Testing
@testable import awesoMux

@Suite(.serialized)
@MainActor
struct NativeTitlebarTests {
    @Test("main content begins at the compact titlebar boundary")
    func mainContentBeginsAtCompactBoundary() async throws {
        #expect(AppTitlebarMetrics.layoutHeight == 44)
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        NativeTitlebarChrome.apply(to: window)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        let hosting = NSHostingView(
            rootView: VStack(spacing: 0) {
                NativeTitlebar { _ in Color.clear }
                NativeTitlebarBoundaryProbe().frame(height: 1)
                Spacer()
            }
            .ignoresSafeArea(.container)
        )
        window.contentView = hosting
        window.alphaValue = 0
        window.orderFrontRegardless()
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        await drainMainQueue()
        hosting.layoutSubtreeIfNeeded()

        let probe = try #require(
            SidebarHostedTestHarness.firstDescendant(of: NativeTitlebarBoundaryProbeView.self, in: hosting)
        )
        let close = try #require(window.standardWindowButton(.closeButton))
        let boundaryFromTop = window.frame.height - probe.convert(probe.bounds, to: nil).maxY
        let controlsBottomFromTop = window.frame.height - close.convert(close.bounds, to: nil).minY
        #expect(abs(boundaryFromTop - AppTitlebarMetrics.layoutHeight) < 0.5)
        #expect(boundaryFromTop > controlsBottomFromTop)
    }

    @Test("primary chrome adopts the standard unified toolbar control insets")
    func standardToolbarInsets() async throws {
        _ = NSApplication.shared
        let frame = NSRect(x: 0, y: 0, width: 900, height: 500)
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        let reference = NSWindow(contentRect: frame, styleMask: style, backing: .buffered, defer: false)
        let main = NSWindow(contentRect: frame, styleMask: style, backing: .buffered, defer: false)
        for window in [reference, main] { window.isReleasedWhenClosed = false }
        defer { for window in [reference, main] { window.close() } }
        reference.toolbar = NSToolbar(identifier: "Native reference")
        reference.toolbar?.displayMode = .iconOnly
        reference.toolbarStyle = .unified
        reference.titleVisibility = .hidden
        let session = TerminalSession(title: "Chrome Preview", workingDirectory: "~")
        let store = SessionStore(
            groups: [SessionGroup(name: "Preview", sessions: [session])],
            selectedSessionID: session.id, pinnedSessionIDs: []
        )
        let hosting = NSHostingView(
            rootView:
                VStack(spacing: 0) {
                    AppTitlebarView(
                        session: session, sessionStore: store, sidebarPosition: .left,
                        hostPresentation: SidebarHostPresentationState())
                    NativeTitlebarBoundaryProbe().frame(height: 20)
                    Spacer()
                }
                .environment(AppSettingsStore(legacySnapshotProvider: { nil }))
                .background(WindowChromeConfigurator(windowRole: .primaryContent))
                .ignoresSafeArea(.container)
        )
        main.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        for window in [reference, main] {
            window.alphaValue = 0
            window.orderFrontRegardless()
            window.layoutIfNeeded()
        }
        await drainMainQueue()
        hosting.layoutSubtreeIfNeeded()
        let expected = try #require(NativeTitlebarGeometry(window: reference))
        let inheritedTopInset = try #require(reference.contentView).safeAreaInsets.top
        #expect(main.toolbar != nil)
        #expect(main.toolbarStyle == .unified)
        #expect(inheritedTopInset > 0)
        #expect(hosting.safeAreaInsets.top == 0)

        hosting.additionalSafeAreaInsets.top = 0
        NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: main)
        await drainMainQueue()
        #expect(hosting.safeAreaInsets.top == 0)
        #expect(abs(hosting.additionalSafeAreaInsets.top + inheritedTopInset) < 0.5)

        let stableAdditionalTopInset = hosting.additionalSafeAreaInsets.top
        NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: main)
        await drainMainQueue()
        #expect(hosting.additionalSafeAreaInsets.top == stableAdditionalTopInset)

        #expect(NativeTitlebarGeometry(window: main) == expected)
        let contentProbe = try #require(
            SidebarHostedTestHarness.firstDescendant(of: NativeTitlebarBoundaryProbeView.self, in: hosting)
        )
        let contentProbeFrame = contentProbe.convert(contentProbe.bounds, to: nil)
        let contentBoundaryFromTop = main.frame.height - contentProbeFrame.maxY
        #expect(abs(contentBoundaryFromTop - AppTitlebarMetrics.layoutHeight) < 0.5)
        let reclaimedStripPoint = CGPoint(x: contentProbeFrame.midX, y: contentProbeFrame.maxY - 4)
        let frameView = try #require(main.contentView?.superview)
        let reclaimedStripHit = try #require(frameView.hitTest(reclaimedStripPoint))
        #expect(reclaimedStripHit === contentProbe, "the reclaimed titlebar strip must belong to app content")

        let dragRegion = try #require(
            SidebarHostedTestHarness.firstDescendant(
                of: NSView.self, in: hosting, where: { $0.toolTip == WindowDragRenameHandle.tooltip }
            ))
        let point = CGPoint(x: dragRegion.bounds.midX, y: dragRegion.bounds.midY)
        let hit = try #require(frameView.hitTest(dragRegion.convert(point, to: nil)))
        #expect(hit === dragRegion, "the native toolbar must not cover workspace interactions")
        SidebarHostedTestHarness.sendDoubleClick(to: hit, at: hit.convert(point, from: dragRegion), in: main)
        await drainMainQueue()
        hosting.layoutSubtreeIfNeeded()
        _ = try #require(SidebarHostedTestHarness.firstDescendant(of: NSTextField.self, in: hosting))
    }

    @Test("settings and floating windows retain compact native controls")
    func auxiliaryWindowsStayCompact() async throws {
        _ = NSApplication.shared
        let frame = NSRect(x: 0, y: 0, width: 500, height: 400)
        let style: NSWindow.StyleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        let reference = NSWindow(contentRect: frame, styleMask: style, backing: .buffered, defer: false)
        let settings = NSWindow(contentRect: frame, styleMask: style, backing: .buffered, defer: false)
        let panel = FloatingSwiftUIPanelWindow(contentRect: frame, backing: .buffered, defer: false)
        let windows = [reference, settings, panel]
        for window in windows { window.isReleasedWhenClosed = false }
        defer { for window in windows { window.close() } }
        reference.titleVisibility = .hidden
        reference.toolbarStyle = .unifiedCompact
        settings.contentView = NSHostingView(rootView: WindowChromeConfigurator(windowRole: .settings))
        panel.showsStandardWindowButtons = true
        for window in windows {
            window.alphaValue = 0
            window.orderFrontRegardless()
            window.layoutIfNeeded()
        }
        await drainMainQueue()
        let expected = try #require(NativeTitlebarGeometry(window: reference))
        for window in [settings, panel] {
            #expect(window.toolbar == nil)
            #expect(NativeTitlebarGeometry(window: window) == expected)
        }
    }

    @Test("main titlebar follows native controls with and without a toolbar", arguments: [false, true])
    func mainBandMatchesNativeControls(hasToolbar: Bool) async throws {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        if hasToolbar { window.toolbar = NSToolbar(identifier: "Titlebar geometry test") }
        let hosting = NSHostingView(
            rootView: VStack(spacing: 0) {
                NativeTitlebar { _ in
                    NativeTitlebarBoundaryProbe()
                        .frame(width: 1, height: 1)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
                Spacer()
            }
            .ignoresSafeArea(.container)
        )
        hosting.safeAreaRegions = []
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 500))
        hosting.frame = container.bounds
        container.addSubview(hosting)
        window.contentView = container
        window.alphaValue = 0
        window.orderFrontRegardless()
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        SidebarHostedTestHarness.settleMainRunLoop()

        await drainMainQueue()
        hosting.layoutSubtreeIfNeeded()
        let close = try #require(window.standardWindowButton(.closeButton))
        let probe = try #require(
            SidebarHostedTestHarness.firstDescendant(of: NativeTitlebarBoundaryProbeView.self, in: hosting)
        )
        let nativeFrame = close.convert(close.bounds, to: nil)
        let centreFromTop = window.frame.height - nativeFrame.midY
        let probeCentreFromTop = window.frame.height - probe.convert(probe.bounds, to: nil).midY
        #expect(abs(probeCentreFromTop - centreFromTop) <= 0.5)
        let measured = try #require(NativeTitlebarGeometry(window: window))
        let zoom = try #require(window.standardWindowButton(.zoomButton))
        #expect(measured.leadingInset >= zoom.convert(zoom.bounds, to: nil).maxX + 10)

        // A toolbar can change after the SwiftUI band has attached. Its
        // native controls must remain the source of the band's geometry.
        window.toolbar = hasToolbar ? nil : NSToolbar(identifier: "Changed titlebar geometry")
        window.layoutIfNeeded()
        await drainMainQueue()
        hosting.layoutSubtreeIfNeeded()
        let changedFrame = close.convert(close.bounds, to: nil)
        let changedProbeCentreFromTop = window.frame.height - probe.convert(probe.bounds, to: nil).midY
        #expect(abs(changedProbeCentreFromTop - (window.frame.height - changedFrame.midY)) <= 0.5)
    }
}

private struct NativeTitlebarBoundaryProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> NativeTitlebarBoundaryProbeView {
        NativeTitlebarBoundaryProbeView()
    }

    func updateNSView(_ nsView: NativeTitlebarBoundaryProbeView, context: Context) {}
}

private final class NativeTitlebarBoundaryProbeView: NSView {}
