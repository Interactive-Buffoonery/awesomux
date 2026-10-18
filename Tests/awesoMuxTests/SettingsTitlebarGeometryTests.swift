import AppKit
import SwiftUI
import Testing
@testable import awesoMux

@Suite(.serialized)
@MainActor
struct SettingsTitlebarGeometryTests {
    @Test("settings content can draw in the native titlebar band")
    func settingsRemovesNativeTopReservation() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let hosting = NSHostingView(rootView: AnyView(Color.clear))
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        try #require(hosting.safeAreaInsets.top > 0)

        hosting.rootView = AnyView(
            Color.clear.background(
                WindowChromeConfigurator(windowRole: .settings, reassertsOnBecomeKey: true, forcesTitlebarRelayout: true)
            )
        )
        hosting.layoutSubtreeIfNeeded()

        #expect(window.awesoMuxWindowRole == .settings)
        #expect(hosting.safeAreaInsets.top == 0)
        let topCancellation = hosting.additionalSafeAreaInsets.top
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        hosting.layoutSubtreeIfNeeded()
        #expect(hosting.additionalSafeAreaInsets.top == topCancellation)
        #expect(hosting.safeAreaInsets.top == 0)
    }
}
