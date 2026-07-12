import AwesoMuxCore
import CoreGraphics
import Testing

@Suite("Floating panel layout")
struct FloatingPanelLayoutTests {
    @Test("centers panel over the parent window")
    func centersPanelOverParentWindow() {
        let origin = FloatingPanelLayout.origin(
            panelSize: FloatingPanelLayout.defaultSize,
            referenceFrame: CGRect(x: 100, y: 80, width: 1_200, height: 900),
            screenFrame: CGRect(x: 100, y: 80, width: 1_200, height: 900)
        )

        // midX 700 - 320 = 380; midY 530 - 240 = 290, both within insets.
        #expect(origin == CGPoint(x: 380, y: 290))
    }

    @Test("clamps panel origin inside screen insets")
    func clampsPanelOriginInsideScreenInsets() {
        let panelSize = FloatingPanelLayout.defaultSize
        let cases: [(referenceFrame: CGRect, screenFrame: CGRect, expected: CGPoint)] = [
            (
                CGRect(x: -2_000, y: 0, width: 400, height: 400),
                CGRect(x: 0, y: 0, width: 1_440, height: 900),
                CGPoint(x: 40, y: 40)
            ),
            (
                CGRect(x: 2_400, y: 2_000, width: 800, height: 900),
                CGRect(x: 0, y: 0, width: 1_440, height: 900),
                CGPoint(x: 760, y: 380)
            ),
            (
                CGRect(x: 0, y: 0, width: 320, height: 240),
                CGRect(x: 0, y: 0, width: 700, height: 600),
                CGPoint(x: 40, y: 40)
            )
        ]

        for item in cases {
            #expect(
                FloatingPanelLayout.origin(
                    panelSize: panelSize,
                    referenceFrame: item.referenceFrame,
                    screenFrame: item.screenFrame
                ) == item.expected
            )
        }
    }

    @Test("returns nil when there is no usable reference or screen frame")
    func returnsNilWithoutReferenceOrScreenFrame() {
        let panelSize = FloatingPanelLayout.defaultSize
        let screenFrame = CGRect(x: 0, y: 0, width: 1_440, height: 900)

        #expect(FloatingPanelLayout.origin(panelSize: panelSize, referenceFrame: nil, screenFrame: screenFrame) == nil)
        #expect(FloatingPanelLayout.origin(panelSize: panelSize, referenceFrame: screenFrame, screenFrame: nil) == nil)
    }
}
