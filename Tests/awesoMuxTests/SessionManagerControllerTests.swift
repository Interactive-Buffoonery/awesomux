import AwesoMuxBridgeProtocol
import AwesoMuxConfig
import AwesoMuxCore
import AwesoMuxTestSupport
import Testing

@testable import awesoMux

@Suite("Session Manager controller")
@MainActor
struct SessionManagerControllerTests {
    @Test("one failed pane cancels confirmation waits for its siblings")
    func failedPaneCancelsSiblingConfirmation() async {
        let center = SessionRecoveryConfirmationCenter()
        let failed = TerminalSessionID.generate()
        let pending = TerminalSessionID.generate()
        center.begin(pending, daemonPID: 42, createdEpoch: 100)
        let clock = ContinuousClock()
        let started = clock.now
        let result = await SessionManagerModel.waitForConfirmations(
            for: [failed, pending], center: center)

        #expect(result == false)
        #expect(center.expectationToken(for: pending) == nil)
        // The sibling's only other exit is its 30s startup timeout; returning
        // sooner proves cancellation, however long a loaded main actor took.
        #expect(started.duration(to: clock.now) < .seconds(30))
    }

    @Test("multi-pane restore requires every daemon to be detached")
    func multiPaneRestoreRequiresEveryDaemon() {
        let first = TerminalSessionID.generate()
        let second = TerminalSessionID.generate()
        let detached = LiveDaemon(
            id: first, pid: 10, createdEpoch: 20, clients: 0, daemonPID: 30)
        let attached = LiveDaemon(
            id: second, pid: 11, createdEpoch: 21, clients: 1, daemonPID: 31)

        #expect(
            SessionManagerModel.restorableDaemons(
                for: [first, second], in: [detached, attached]) == nil)
        #expect(
            SessionManagerModel.restorableDaemons(for: [first, second], in: [detached]) == nil)
        #expect(
            SessionManagerModel.restorableDaemons(
                for: [first, second],
                in: [
                    detached,
                    LiveDaemon(
                        id: second, pid: 11, createdEpoch: 21, clients: 0, daemonPID: 31
                    ),
                ]
            )?.count == 2)
    }
}
