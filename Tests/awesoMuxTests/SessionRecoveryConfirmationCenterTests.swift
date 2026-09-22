import AwesoMuxBridgeProtocol
import Testing
@testable import awesoMux

@MainActor
@Suite("Session recovery confirmation")
struct SessionRecoveryConfirmationCenterTests {
    @Test("confirmation arriving before wait is consumed")
    func confirmationBeforeWait() async {
        let center = SessionRecoveryConfirmationCenter()
        let id = TerminalSessionID.generate()
        center.begin(id, daemonPID: 42, createdEpoch: 100)
        center.confirm(id, daemonPID: 42, createdEpoch: 100)

        #expect(await center.wait(for: id, timeout: .milliseconds(10)))
    }

    @Test("replacement daemon does not confirm recovery")
    func replacementDoesNotConfirm() async {
        let center = SessionRecoveryConfirmationCenter()
        let id = TerminalSessionID.generate()
        center.begin(id, daemonPID: 42, createdEpoch: 100)
        let task = Task { await center.wait(for: id, timeout: .seconds(10)) }
        await Task.yield()

        center.confirm(id, daemonPID: 99, createdEpoch: 101)

        #expect(await task.value == false)
    }

    @Test("begin retires an existing waiter")
    func beginRetiresWaiter() async {
        let center = SessionRecoveryConfirmationCenter()
        let id = TerminalSessionID.generate()
        center.begin(id, daemonPID: 42, createdEpoch: 100)
        let task = Task { await center.wait(for: id, timeout: .seconds(10)) }
        await Task.yield()

        center.begin(id, daemonPID: 42, createdEpoch: 100)

        #expect(await task.value == false)
    }

    @Test("second wait retires the first waiter")
    func secondWaitRetiresFirst() async {
        let center = SessionRecoveryConfirmationCenter()
        let id = TerminalSessionID.generate()
        center.begin(id, daemonPID: 42, createdEpoch: 100)
        let first = Task { await center.wait(for: id, timeout: .seconds(10)) }
        await Task.yield()
        let second = Task { await center.wait(for: id, timeout: .seconds(10)) }
        await Task.yield()

        center.confirm(id, daemonPID: 42, createdEpoch: 100)

        #expect(await first.value == false)
        #expect(await second.value)
    }

    @Test("task cancellation retires its waiter")
    func cancellationRetiresWaiter() async {
        let center = SessionRecoveryConfirmationCenter()
        let id = TerminalSessionID.generate()
        center.begin(id, daemonPID: 42, createdEpoch: 100)
        let task = Task { await center.wait(for: id, timeout: .seconds(10)) }
        await Task.yield()

        task.cancel()

        #expect(await task.value == false)
    }
}
