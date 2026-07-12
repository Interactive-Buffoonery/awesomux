import CoreGraphics
import Testing
@testable import AwesoMuxCore

@Suite("Pop-up terminal layout")
struct PopUpTerminalLayoutTests {
    @Test("expanded card and tab align to the lower-right edge")
    func lowerRightEdgeAlignment() {
        let reference = CGRect(x: 100, y: 100, width: 1000, height: 700)
        let screen = CGRect(x: 0, y: 0, width: 1200, height: 900)

        #expect(PopUpTerminalLayout.origin(for: PopUpTerminalLayout.defaultExpandedSize, referenceFrame: reference, screenFrame: screen) == CGPoint(x: 580, y: 116))
        #expect(PopUpTerminalLayout.origin(for: PopUpTerminalLayout.cornerTabSize, referenceFrame: reference, screenFrame: screen) == CGPoint(x: 840, y: 116))
    }

    @Test("expanded size clamps for a narrow parent without dropping below minimum")
    func narrowParentClamp() {
        let size = PopUpTerminalLayout.expandedSize(
            preferred: CGSize(width: 700, height: 500),
            availableFrame: CGRect(x: 0, y: 0, width: 420, height: 300)
        )
        #expect(size == CGSize(width: 388, height: 268))
        #expect(size.width >= PopUpTerminalLayout.minimumExpandedSize.width)
        #expect(size.height >= PopUpTerminalLayout.minimumExpandedSize.height)
    }

    @Test("terminal footer inset keeps the card above bottom chrome")
    func terminalFooterInset() {
        let reference = CGRect(x: 100, y: 100, width: 1000, height: 700)
        let screen = CGRect(x: 0, y: 0, width: 1200, height: 900)
        let footerHeight: CGFloat = 39.5

        let size = PopUpTerminalLayout.expandedSize(
            preferred: CGSize(width: 700, height: 700),
            availableFrame: reference,
            bottomInset: footerHeight
        )
        let origin = PopUpTerminalLayout.origin(
            for: size,
            referenceFrame: reference,
            screenFrame: screen,
            bottomInset: footerHeight
        )

        #expect(size.height == 644.5)
        #expect(origin.y == reference.minY + footerHeight)
    }
}
