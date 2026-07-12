import Testing
@testable import awesoMux

@Suite("Floating panel external re-key announcement")
@MainActor
struct FloatingPanelExternalReKeyAnnouncementTests {
    @Test("announces click re-key of a visible non-key panel")
    func announcesClickReKeyOfVisibleNonKeyPanel() {
        #expect(
            TerminalPanelController.shouldAnnounceExternalReKeyForTesting(
                wasKey: false,
                isKey: true,
                isVisible: true,
                isPresentingShow: false
            )
        )
    }

    @Test("stays silent while show() owns the presentation announcement")
    func staysSilentWhileShowOwnsAnnouncement() {
        #expect(
            !TerminalPanelController.shouldAnnounceExternalReKeyForTesting(
                wasKey: false,
                isKey: true,
                isVisible: true,
                isPresentingShow: true
            )
        )
    }

    @Test("stays silent on first order-front before isVisible is set")
    func staysSilentOnFirstOrderFrontBeforeVisible() {
        #expect(
            !TerminalPanelController.shouldAnnounceExternalReKeyForTesting(
                wasKey: false,
                isKey: true,
                isVisible: false,
                isPresentingShow: false
            )
        )
    }

    @Test("stays silent when the panel is already key")
    func staysSilentWhenAlreadyKey() {
        #expect(
            !TerminalPanelController.shouldAnnounceExternalReKeyForTesting(
                wasKey: true,
                isKey: true,
                isVisible: true,
                isPresentingShow: false
            )
        )
    }

    @Test("stays silent on resignKey")
    func staysSilentOnResignKey() {
        #expect(
            !TerminalPanelController.shouldAnnounceExternalReKeyForTesting(
                wasKey: true,
                isKey: false,
                isVisible: true,
                isPresentingShow: false
            )
        )
    }
}
