import AwesoMuxBridgeProtocol
import Testing
@testable import awesoMux

@MainActor
@Suite("Session recovery confirmation")
struct SessionRecoveryConfirmationCenterTests {
    @Test("confirmation arriving before wait is consumed")
    func confirmationBeforeWait() async throws {
        let center = SessionRecoveryConfirmationCenter()
        let id = TerminalSessionID.generate()
        center.begin(id, daemonPID: 42, createdEpoch: 100)
        try confirm(center, id: id, daemonPID: 42, createdEpoch: 100)

        #expect(await center.wait(for: id, timeout: .milliseconds(10)))
    }

    @Test("confirmation timeout starts when attach starts")
    func timeoutStartsWithAttach() async throws {
        let center = SessionRecoveryConfirmationCenter()
        let id = TerminalSessionID.generate()
        center.begin(id, daemonPID: 42, createdEpoch: 100)
        let task = Task { await center.wait(for: id, timeout: .milliseconds(10)) }

        try await Task.sleep(for: .milliseconds(25))
        try confirm(center, id: id, daemonPID: 42, createdEpoch: 100)

        #expect(await task.value)
    }

    @Test("started attach times out without confirmation")
    func startedAttachTimesOut() async {
        let center = SessionRecoveryConfirmationCenter()
        let id = TerminalSessionID.generate()
        center.begin(id, daemonPID: 42, createdEpoch: 100)
        center.didStartAttach(id)

        #expect(await center.wait(for: id, timeout: .milliseconds(10)) == false)
    }

    @Test("attach that never starts retires its expectation")
    func neverStartedAttachTimesOut() async {
        let center = SessionRecoveryConfirmationCenter()
        let id = TerminalSessionID.generate()
        center.begin(id, daemonPID: 42, createdEpoch: 100)

        #expect(await center.wait(for: id, startupTimeout: .milliseconds(10)) == false)
        #expect(center.expectationToken(for: id) == nil)
    }

    @Test("pre-attach failure retires its waiter immediately")
    func preAttachFailureRetiresWaiter() async {
        let center = SessionRecoveryConfirmationCenter()
        let id = TerminalSessionID.generate()
        center.begin(id, daemonPID: 42, createdEpoch: 100)
        let task = Task { await center.wait(for: id, timeout: .seconds(10)) }
        await Task.yield()

        center.cancel(id)

        #expect(await task.value == false)
    }

    @Test("explicit cancellation revokes buffered confirmation")
    func cancellationRevokesBufferedConfirmation() async throws {
        let center = SessionRecoveryConfirmationCenter()
        let id = TerminalSessionID.generate()
        center.begin(id, daemonPID: 42, createdEpoch: 100)
        try confirm(center, id: id, daemonPID: 42, createdEpoch: 100)

        center.cancel(id)

        #expect(await center.wait(for: id, timeout: .milliseconds(10)) == false)
    }

    @Test("stale expectation token cannot cancel its successor")
    func staleExpectationCannotCancelSuccessor() async throws {
        let center = SessionRecoveryConfirmationCenter()
        let id = TerminalSessionID.generate()
        center.begin(id, daemonPID: 42, createdEpoch: 100)
        let staleToken = try #require(center.expectationToken(for: id))
        center.begin(id, daemonPID: 42, createdEpoch: 100)

        center.cancel(id, expectationToken: staleToken)
        try confirm(center, id: id, daemonPID: 42, createdEpoch: 100)

        #expect(await center.wait(for: id, timeout: .milliseconds(10)))
    }

    @Test("stale confirmation cannot decide its successor")
    func staleConfirmationCannotDecideSuccessor() async throws {
        let center = SessionRecoveryConfirmationCenter()
        let id = TerminalSessionID.generate()
        center.begin(id, daemonPID: 42, createdEpoch: 100)
        let staleToken = try #require(center.expectationToken(for: id))
        center.begin(id, daemonPID: 42, createdEpoch: 100)
        let currentToken = try #require(center.expectationToken(for: id))
        let task = Task { await center.wait(for: id, timeout: .seconds(10)) }
        await Task.yield()

        center.confirm(
            id, expectationToken: staleToken, daemonPID: 42, createdEpoch: 100
        )
        center.confirm(
            id, expectationToken: staleToken, daemonPID: 99, createdEpoch: 101
        )
        center.confirm(
            id, expectationToken: currentToken, daemonPID: 42, createdEpoch: 100
        )

        #expect(await task.value)
    }

    @Test("token cancellation revokes its buffered confirmation")
    func tokenCancellationRevokesBufferedConfirmation() async throws {
        let center = SessionRecoveryConfirmationCenter()
        let id = TerminalSessionID.generate()
        center.begin(id, daemonPID: 42, createdEpoch: 100)
        let token = try #require(center.expectationToken(for: id))
        center.confirm(
            id, expectationToken: token, daemonPID: 42, createdEpoch: 100
        )

        center.cancel(id, expectationToken: token)

        #expect(await center.wait(for: id, timeout: .milliseconds(10)) == false)
    }

    @Test("replacement daemon does not confirm recovery")
    func replacementDoesNotConfirm() async throws {
        let center = SessionRecoveryConfirmationCenter()
        let id = TerminalSessionID.generate()
        center.begin(id, daemonPID: 42, createdEpoch: 100)
        let task = Task { await center.wait(for: id, timeout: .seconds(10)) }
        await Task.yield()

        try confirm(center, id: id, daemonPID: 99, createdEpoch: 101)

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
    func secondWaitRetiresFirst() async throws {
        let center = SessionRecoveryConfirmationCenter()
        let id = TerminalSessionID.generate()
        center.begin(id, daemonPID: 42, createdEpoch: 100)
        let first = Task { await center.wait(for: id, timeout: .seconds(10)) }
        await Task.yield()
        let second = Task { await center.wait(for: id, timeout: .seconds(10)) }
        await Task.yield()

        try confirm(center, id: id, daemonPID: 42, createdEpoch: 100)

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

    private func confirm(
        _ center: SessionRecoveryConfirmationCenter,
        id: TerminalSessionID,
        daemonPID: Int,
        createdEpoch: Int
    ) throws {
        let token = try #require(center.expectationToken(for: id))
        center.confirm(
            id, expectationToken: token, daemonPID: daemonPID, createdEpoch: createdEpoch
        )
    }
}
