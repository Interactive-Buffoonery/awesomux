import AppKit
import AwesoMuxCore
import Foundation
import Testing
@testable import awesoMux

@MainActor
@Suite("Secure input coordination")
struct SecureInputCoordinatorTests {
    @Test("balances system state across focused requesting panes")
    func balancesAcrossPanes() {
        let calls = CallRecorder()
        let coordinator = makeCoordinator(calls: calls)
        let first = TerminalPane.ID()
        let second = TerminalPane.ID()

        coordinator.setFocused(true, for: first)
        coordinator.apply(.on, for: first)
        coordinator.apply(.on, for: first)
        coordinator.setFocused(true, for: second)
        coordinator.apply(.on, for: second)
        coordinator.apply(.off, for: first)

        #expect(calls.enableCount == 1)
        #expect(calls.disableCount == 0)

        coordinator.removePane(second)

        #expect(calls.enableCount == 1)
        #expect(calls.disableCount == 1)
    }

    @Test("tracks requests per pane while focus moves")
    func followsFocus() {
        let calls = CallRecorder()
        let coordinator = makeCoordinator(calls: calls)
        let first = TerminalPane.ID()
        let second = TerminalPane.ID()

        coordinator.apply(.on, for: first)
        coordinator.apply(.on, for: second)
        coordinator.setFocused(true, for: first)
        coordinator.setFocused(false, for: first)
        coordinator.setFocused(true, for: second)

        #expect(calls.enableCount == 2)
        #expect(calls.disableCount == 1)
        #expect(coordinator.isSystemEnabled)
    }

    @Test("toggle and reset are pane-local and balanced")
    func togglesAndResets() {
        let calls = CallRecorder()
        let coordinator = makeCoordinator(calls: calls)
        let pane = TerminalPane.ID()

        coordinator.setFocused(true, for: pane)
        coordinator.apply(.toggle, for: pane)
        coordinator.reset()

        #expect(calls.enableCount == 1)
        #expect(calls.disableCount == 1)
        #expect(!coordinator.isSystemEnabled)
    }

    @Test("app activation temporarily yields and restores secure input")
    func followsApplicationActivation() {
        let calls = CallRecorder()
        let coordinator = makeCoordinator(calls: calls)
        let pane = TerminalPane.ID()

        coordinator.setFocused(true, for: pane)
        coordinator.apply(.on, for: pane)
        coordinator.applicationDidResignActive()
        coordinator.applicationDidBecomeActive()

        #expect(calls.enableCount == 2)
        #expect(calls.disableCount == 1)
        #expect(coordinator.isSystemEnabled)
    }

    @Test("failed system calls do not change applied-state bookkeeping")
    func preservesStateAfterFailures() {
        let calls = CallRecorder(enableStatus: OSStatus(paramErr))
        let coordinator = makeCoordinator(calls: calls)
        let pane = TerminalPane.ID()

        coordinator.setFocused(true, for: pane)
        coordinator.apply(.on, for: pane)

        #expect(calls.enableCount == 1)
        #expect(!coordinator.isSystemEnabled)

        calls.enableStatus = noErr
        coordinator.apply(.on, for: pane)
        #expect(calls.enableCount == 2)
        #expect(coordinator.isSystemEnabled)

        calls.disableStatus = OSStatus(paramErr)
        coordinator.removePane(pane)
        #expect(calls.disableCount == 1)
        #expect(coordinator.isSystemEnabled)
    }

    private func makeCoordinator(calls: CallRecorder) -> SecureInputCoordinator {
        SecureInputCoordinator(
            systemCalls: .init(
                enable: {
                    calls.enableCount += 1
                    return calls.enableStatus
                },
                disable: {
                    calls.disableCount += 1
                    return calls.disableStatus
                }
            ),
            notificationCenter: nil,
            isApplicationActive: true
        )
    }
}

@MainActor
private final class CallRecorder {
    var enableCount = 0
    var disableCount = 0
    var enableStatus: OSStatus
    var disableStatus: OSStatus

    init(enableStatus: OSStatus = noErr, disableStatus: OSStatus = noErr) {
        self.enableStatus = enableStatus
        self.disableStatus = disableStatus
    }
}
