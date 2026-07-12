import DesignSystem
import Testing
@testable import awesoMux

@Suite("Settings titlebar metrics")
struct SettingsTitlebarMetricsTests {
    @Test("matches the main window titlebar height and stoplight clearance")
    func matchesMainWindowChrome() {
        #expect(SettingsTitlebarMetrics.height == AwSpacing.titlebar)
        #expect(SettingsTitlebarMetrics.brandLeadingInset == AppTitlebarMetrics.trafficLightClearance)
        #expect(SettingsTitlebarMetrics.extendsIntoNativeTitlebar)
    }
}
