import Testing
@testable import awesoMux

@Suite("App titlebar metrics")
struct AppTitlebarMetricsTests {
    @Test("shared titlebar metrics stay stable")
    func sharedTitlebarMetricsStayStable() {
        #expect(AppTitlebarMetrics.trafficLightClearance == 78)
        #expect(AppTitlebarMetrics.contentColumnGutter == 16)
        #expect(AppTitlebarMetrics.lockupPadding == 10)
    }
}
