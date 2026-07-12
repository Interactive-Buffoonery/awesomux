import Testing
@testable import awesoMux

@Suite("QuitTerminationPolicy")
struct QuitTerminationPolicyTests {
    @Test("system quit without risky sessions terminates immediately")
    func systemQuitWithoutRiskySessionsTerminatesImmediately() {
        let decision = QuitTerminationPolicy.decision(
            isSystemInitiatedQuit: true,
            hasRiskySessions: false
        )

        #expect(decision == .terminateNow)
    }

    @Test("system quit with risky sessions presents timeout warning")
    func systemQuitWithRiskySessionsPresentsTimeoutWarning() {
        let decision = QuitTerminationPolicy.decision(
            isSystemInitiatedQuit: true,
            hasRiskySessions: true
        )

        #expect(decision == .presentSystemQuitRiskWarning)
    }

    @Test("user quit with risky sessions presents blocking alert")
    func userQuitWithRiskySessionsPresentsBlockingAlert() {
        let decision = QuitTerminationPolicy.decision(
            isSystemInitiatedQuit: false,
            hasRiskySessions: true
        )

        #expect(decision == .presentUserQuitRiskAlert)
    }

    @Test("user quit without risky sessions terminates immediately")
    func userQuitWithoutRiskySessionsTerminatesImmediately() {
        let decision = QuitTerminationPolicy.decision(
            isSystemInitiatedQuit: false,
            hasRiskySessions: false
        )

        #expect(decision == .terminateNow)
    }
}
