import Testing

@testable import awesoMux

@MainActor
@Suite("SettingsNavigator")
struct SettingsNavigatorTests {
    @Test("diagnostics analytics intent survives scroll-anchor consumption")
    func diagnosticsAnalyticsIntent() {
        let navigator = SettingsNavigator()
        navigator.pendingScrollAnchor = "analytics-events"
        navigator.noteAnalyticsDiagnosticsIntent(.analytics)
        navigator.pendingScrollAnchor = nil

        #expect(navigator.consumeAnalyticsDiagnosticsIntent() == .analytics)
        #expect(navigator.consumeAnalyticsDiagnosticsIntent() == .overview)
    }

    @Test("accessibility focus intent is consumed only by its destination")
    func accessibilityFocusIntentTargetsDestination() {
        let navigator = SettingsNavigator()

        navigator.scrollDidLand(on: "analytics-events")

        #expect(!navigator.consumeAccessibilityFocus(for: "diagnostic-events"))
        #expect(navigator.pendingAccessibilityFocusAnchor == "analytics-events")
        #expect(navigator.consumeAccessibilityFocus(for: "analytics-events"))
        #expect(navigator.pendingAccessibilityFocusAnchor == nil)
        #expect(!navigator.consumeAccessibilityFocus(for: "analytics-events"))
    }
}
