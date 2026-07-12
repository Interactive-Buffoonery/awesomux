import Testing
import AwesoMuxConfig
@testable import awesoMux

@Suite("Daemon garbage collector launch policy")
struct DaemonGarbageCollectorTests {
    @Test("command bridge enablement is not a launch sweep prerequisite")
    func commandBridgeEnablementIsNotAPrerequisite() {
        let bridgeDisabled = DaemonGarbageCollector.launchSweepConfiguration(
            terminalSettings: TerminalConfig(
                commandBridgeEnabled: false,
                daemonIdleCapEnabled: true,
                daemonIdleCapMinutes: 42
            ),
            isRestoreEnabled: true,
            hasUnresolvedRecoveryWarning: false
        )
        let bridgeEnabled = DaemonGarbageCollector.launchSweepConfiguration(
            terminalSettings: TerminalConfig(
                commandBridgeEnabled: true,
                daemonIdleCapEnabled: true,
                daemonIdleCapMinutes: 42
            ),
            isRestoreEnabled: true,
            hasUnresolvedRecoveryWarning: false
        )

        #expect(bridgeDisabled?.capThresholdSeconds == 2_520)
        #expect(bridgeEnabled == bridgeDisabled)
    }

    @Test("restore and recovery guards still suppress launch sweeps")
    func safetyGuardsSuppressSweep() {
        #expect(DaemonGarbageCollector.launchSweepConfiguration(
            terminalSettings: .defaultValue,
            isRestoreEnabled: false,
            hasUnresolvedRecoveryWarning: false
        ) == nil)
        #expect(DaemonGarbageCollector.launchSweepConfiguration(
            terminalSettings: .defaultValue,
            isRestoreEnabled: true,
            hasUnresolvedRecoveryWarning: true
        ) == nil)
    }
}
