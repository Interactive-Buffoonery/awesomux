import DesignSystem
import SwiftUI
import Testing

/// Direct coverage for the public `AwColors.searchHighlightHex(theme:)`
/// accessor itself, independent of `GhosttyConfigManagerTests` (which pins
/// the full libghostty config-string formatting, not just the palette
/// lookup this API performs).
@Suite("AwColors search highlight hex accessor")
struct AwColorsSearchHighlightTests {
    @Test("dark resolves to the mocha mauve/peach pair")
    func darkResolvesToMochaPair() {
        let hex = Color.aw.searchHighlightHex(theme: .dark)
        #expect(hex.background == "#cba6f7")
        #expect(hex.selectedBackground == "#fab387")
    }

    @Test("light resolves to the latte mauve/peach pair")
    func lightResolvesToLattePair() {
        let hex = Color.aw.searchHighlightHex(theme: .light)
        #expect(hex.background == "#8839ef")
        #expect(hex.selectedBackground == "#fe640b")
    }
}
