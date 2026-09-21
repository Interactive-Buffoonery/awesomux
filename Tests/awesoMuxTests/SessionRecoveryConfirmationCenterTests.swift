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
        center.begin(id)
        center.confirm(id)

        #expect(await center.wait(for: id, timeout: .milliseconds(10)))
    }

    @Test("begin retires an existing waiter")
    func beginRetiresWaiter() async {
        let center = SessionRecoveryConfirmationCenter()
        let id = TerminalSessionID.generate()
        center.begin(id)
        let task = Task { await center.wait(for: id, timeout: .seconds(10)) }
        await Task.yield()

        center.begin(id)

        #expect(await task.value == false)
    }

    @Test("task cancellation retires its waiter")
    func cancellationRetiresWaiter() async {
        let center = SessionRecoveryConfirmationCenter()
        let id = TerminalSessionID.generate()
        center.begin(id)
        let task = Task { await center.wait(for: id, timeout: .seconds(10)) }
        await Task.yield()

        task.cancel()

        #expect(await task.value == false)
    }
}
