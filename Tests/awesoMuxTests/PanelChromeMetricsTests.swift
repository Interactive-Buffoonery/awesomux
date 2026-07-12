import Testing
@testable import awesoMux

@Suite("Panel chrome metrics")
struct PanelChromeMetricsTests {
    @Test("floating panels share the Session Manager close-button edge inset")
    func closeButtonEdgeInsetMatchesSessionManager() {
        #expect(FloatingPanelChromeMetrics.closeButtonEdgeInset == 18)
    }

    @Test("keyboard focus ring stays opaque and wide enough to be visible")
    func focusRingMeetsVisibilityContract() {
        #expect(FloatingPanelChromeMetrics.focusRingOpacity == 1)
        #expect(FloatingPanelChromeMetrics.focusRingLineWidth == 1.25)
    }
}
