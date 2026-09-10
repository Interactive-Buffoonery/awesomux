import SwiftUI
import Testing
@testable import awesoMux

@Suite("Consent scroll navigation")
struct ConsentScrollNavigationTests {
    @Test("End reaches the final suffix and Home returns to the beginning")
    func reachesBothEnds() {
        #expect(offset(.end, current: 0) == 1720)
        #expect(offset(.home, current: 1720) == 0)
    }

    @Test("arrow and page scrolling stay within the document")
    func boundedSteps() {
        #expect(offset(.upArrow, current: 0) == 0)
        #expect(offset(.downArrow, current: 0) == 24)
        #expect(offset(.pageDown, current: 24) == 304)
        #expect(offset(.pageUp, current: 304) == 24)
        #expect(offset(.pageDown, current: 1700) == 1720)
        #expect(offset(.downArrow, current: 1720) == 1720)
    }

    @Test("short content never scrolls outside its bounds")
    func shortContent() {
        #expect(ConsentScrollNavigation.offset(for: .end, current: 0, contentHeight: 20, viewportHeight: 280) == 0)
    }

    @Test("decision and focus navigation keys are left to their owners")
    func leavesOtherKeysAlone() {
        for key: KeyEquivalent in [.return, .escape, .tab, "a"] {
            #expect(offset(key, current: 120) == nil)
        }
    }

    private func offset(_ key: KeyEquivalent, current: CGFloat) -> CGFloat? {
        ConsentScrollNavigation.offset(for: key, current: current, contentHeight: 2000, viewportHeight: 280)
    }
}
