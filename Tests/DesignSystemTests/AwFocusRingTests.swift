import Testing
@testable import DesignSystem

@Suite("AwFocusRing")
struct AwFocusRingTests {
    @Test("focus ring line widths are stable and strengthen under increased contrast")
    func lineWidthContract() {
        #expect(AwFocusRing.standardLineWidth == 1.25)
        #expect(AwFocusRing.increasedContrastLineWidth == 2)
        #expect(AwFocusRing.lineWidth(increasedContrast: false) == 1.25)
        #expect(AwFocusRing.lineWidth(increasedContrast: true) == 2)
    }
}
