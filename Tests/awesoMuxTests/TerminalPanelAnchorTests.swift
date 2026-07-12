import CoreGraphics
import Testing
@testable import awesoMux
import AwesoMuxCore

@Suite("Terminal panel anchor dispatch")
struct TerminalPanelAnchorTests {
    private let size = CGSize(width: 520, height: 360)
    private let reference = CGRect(x: 100, y: 100, width: 1200, height: 800)
    private let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    @Test("bottom-trailing anchor matches the companion layout origin")
    func bottomTrailingMatchesCompanion() {
        let expected = PopUpTerminalLayout.origin(
            for: size, referenceFrame: reference, screenFrame: screen, bottomInset: 16
        )
        #expect(
            TerminalPanelController.expandedOrigin(
                mode: .bottomTrailing, size: size, reference: reference, screen: screen, bottomInset: 16
            ) == expected
        )
    }

    @Test("center anchor matches the floating layout origin")
    func centerMatchesFloating() {
        let expected = FloatingPanelLayout.origin(
            panelSize: size, referenceFrame: reference, screenFrame: screen
        )
        #expect(
            TerminalPanelController.expandedOrigin(
                mode: .center, size: size, reference: reference, screen: screen, bottomInset: 16
            ) == expected
        )
    }
}
