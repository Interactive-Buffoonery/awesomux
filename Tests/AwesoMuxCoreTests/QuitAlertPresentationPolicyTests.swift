import AwesoMuxCore
import Testing

@Suite("QuitAlertPresentationPolicy")
struct QuitAlertPresentationPolicyTests {
    typealias Candidate = QuitAlertPresentationPolicy.WindowCandidate<String>

    @Test("suitable main window wins")
    func suitableMainWindowWins() {
        let target = QuitAlertPresentationPolicy.target(
            mainWindow: candidate("main"),
            keyWindow: candidate("key"),
            orderedWindows: [candidate("fallback")]
        )

        #expect(target == .sheet("main"))
    }

    @Test("suitable key window wins when main is unsuitable")
    func suitableKeyWindowWinsWhenMainIsUnsuitable() {
        let target = QuitAlertPresentationPolicy.target(
            mainWindow: candidate("main", isVisible: false),
            keyWindow: candidate("key"),
            orderedWindows: [candidate("fallback")]
        )

        #expect(target == .sheet("key"))
    }

    @Test("fallback sheet-free window is used when focus is not sheet-blocked")
    func fallbackSheetFreeWindowIsUsedWhenFocusIsNotSheetBlocked() {
        let target = QuitAlertPresentationPolicy.target(
            mainWindow: nil,
            keyWindow: nil,
            orderedWindows: [
                candidate("hidden", isVisible: false),
                candidate("fallback")
            ]
        )

        #expect(target == .sheet("fallback"))
    }

    @Test("main window attached sheet causes app-modal fallback")
    func mainWindowAttachedSheetCausesAppModalFallback() {
        let target = QuitAlertPresentationPolicy.target(
            mainWindow: candidate("main", hasAttachedSheet: true),
            keyWindow: nil,
            orderedWindows: [candidate("fallback")]
        )

        #expect(target == .appModal)
    }

    @Test("key window attached sheet causes app-modal fallback")
    func keyWindowAttachedSheetCausesAppModalFallback() {
        let target = QuitAlertPresentationPolicy.target(
            mainWindow: nil,
            keyWindow: candidate("key", hasAttachedSheet: true),
            orderedWindows: [candidate("fallback")]
        )

        #expect(target == .appModal)
    }

    @Test("key window that is an attached sheet causes app-modal fallback")
    func keyWindowThatIsAttachedSheetCausesAppModalFallback() {
        let target = QuitAlertPresentationPolicy.target(
            mainWindow: nil,
            keyWindow: candidate("key-sheet", canBecomeMain: false, isAttachedSheet: true),
            orderedWindows: [candidate("fallback")]
        )

        #expect(target == .appModal)
    }

    @Test("attached sheet in fallback list is skipped")
    func attachedSheetInFallbackListIsSkipped() {
        let target = QuitAlertPresentationPolicy.target(
            mainWindow: nil,
            keyWindow: nil,
            orderedWindows: [
                candidate("sheet", isAttachedSheet: true),
                candidate("fallback")
            ]
        )

        #expect(target == .sheet("fallback"))
    }

    @Test("no suitable windows causes app-modal fallback")
    func noSuitableWindowsCausesAppModalFallback() {
        let target = QuitAlertPresentationPolicy.target(
            mainWindow: nil,
            keyWindow: nil,
            orderedWindows: [
                candidate("hidden", isVisible: false),
                candidate("blocked", canBecomeMain: false)
            ]
        )

        #expect(target == .appModal)
    }

    private func candidate(
        _ id: String,
        isVisible: Bool = true,
        canBecomeMain: Bool = true,
        hasAttachedSheet: Bool = false,
        isAttachedSheet: Bool = false
    ) -> Candidate {
        Candidate(
            id: id,
            isVisible: isVisible,
            canBecomeMain: canBecomeMain,
            hasAttachedSheet: hasAttachedSheet,
            isAttachedSheet: isAttachedSheet
        )
    }
}
