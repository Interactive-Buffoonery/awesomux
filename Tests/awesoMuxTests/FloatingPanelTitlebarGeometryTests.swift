import AppKit
import DesignSystem
import Testing

@testable import awesoMux

/// Pins `AppTitlebarMetrics.panelTitlebarHeight` to the title bar AppKit
/// actually lays out for these panels. Getting it wrong is a 3pt error that
/// reads as a sloppy baseline rather than a geometry bug, which sends the next
/// reader off adjusting font sizes — so the number is asserted against a real
/// window instead of remembered.
///
/// Scope, stated plainly: this is a metric contract, not a component test. It
/// never instantiates `FloatingPanelTitlebar`, so it would still pass if that
/// view stopped consuming the metric. The band's own rendering — height,
/// clearance, gradient, hairline, heading semantics — is covered by GUI smoke.
@Suite("Floating panel titlebar geometry")
@MainActor
struct FloatingPanelTitlebarGeometryTests {
    @Test("band height matches the native titlebar these panels actually get")
    func bandHeightMatchesNativeTitlebar() throws {
        let panel = makePanel()
        defer { panel.close() }

        let close = try #require(panel.standardWindowButton(.closeButton))
        let container = try #require(close.superview)

        #expect(container.frame.height == AppTitlebarMetrics.panelTitlebarHeight)
    }

    @Test("the band centres its title on the traffic lights' centre line")
    func bandCentresTitleOnTrafficLights() throws {
        let panel = makePanel()
        defer { panel.close() }

        let close = try #require(panel.standardWindowButton(.closeButton))
        let container = try #require(close.superview)

        // AppKit measures from the bottom in this container, so the button's
        // centre distance from the top is what the SwiftUI band has to match.
        let centreFromTop = container.frame.height - close.frame.midY

        // The band centres its label, so its centre line is half its height.
        #expect(centreFromTop == AppTitlebarMetrics.panelTitlebarHeight / 2)
    }

    @Test("the toolbar-bearing titlebar height is not the panel height")
    func toolbarTitlebarHeightIsNotThePanelHeight() {
        // Regression guard for the tempting simplification. `AwSpacing.titlebar`
        // is the main window's and Settings' title bar, which are taller
        // because they set `toolbarStyle = .unifiedCompact`. Reusing it here
        // silently drops the title 3pt below the lights.
        #expect(AppTitlebarMetrics.panelTitlebarHeight != AwSpacing.titlebar)
    }

    private func makePanel() -> FloatingSwiftUIPanelWindow {
        let panel = FloatingSwiftUIPanelWindow(
            contentRect: NSRect(origin: .zero, size: CGSize(width: 400, height: 300)),
            backing: .buffered,
            defer: false
        )
        panel.showsStandardWindowButtons = true
        return panel
    }
}
