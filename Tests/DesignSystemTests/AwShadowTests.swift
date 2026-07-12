import CoreGraphics
import Testing
@testable import DesignSystem

@Suite("AwShadow")
struct AwShadowTests {
    @Test(
        "heavy animated shadows rasterize above threshold",
        arguments: [
            (shadow: AwShadow.window, radius: 24),
            (shadow: .sheet, radius: 28),
            (shadow: .toast, radius: 18)
        ]
    )
    func heavyAnimatedShadowsRasterize(shadow: AwShadow, radius: CGFloat) {
        #expect(shadow.radius == radius)
        #expect(shadow.shouldRasterizeAnimatedShadow)
    }

    @Test("threshold overlay stays live")
    func thresholdOverlayStaysLive() {
        #expect(AwShadow.overlay.radius == AwShadow.rasterizedRadiusThreshold)
        #expect(!AwShadow.overlay.shouldRasterizeAnimatedShadow)
    }

    @Test(
        "smaller shadows stay live",
        arguments: [
            (shadow: AwShadow.findBar, radius: 14),
            (shadow: .handle, radius: 8)
        ]
    )
    func smallerShadowsStayLive(shadow: AwShadow, radius: CGFloat) {
        #expect(shadow.radius == radius)
        #expect(!shadow.shouldRasterizeAnimatedShadow)
    }
}
