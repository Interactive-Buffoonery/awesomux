import AwesoMuxBridgeProtocol
import AwesoMuxTestSupport
import Foundation
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

    @Test("attach starts the confirmation deadline after startup has waited longer than that deadline")
    func timeoutStartsWithAttach() async {
        let center = SessionRecoveryConfirmationCenter()
        let id = TerminalSessionID.generate()
        center.begin(id, daemonPID: 42, createdEpoch: 100)
        var completed = false
        let task = Task {
            let result = await center.wait(for: id, timeout: .milliseconds(10))
            completed = true
            return result
        }
        await withCheckedContinuation { continuation in
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(25)) { continuation.resume() }
        }
        #expect(!completed)
        center.didStartAttach(id)
        #expect(await task.value == false)
        #expect(center.expectationToken(for: id) == nil)
    }

    @Test(
        "timeouts, cancellation, and replacement retire exactly their waiter",
        arguments: [
            "startedAttachTimesOut", "neverStartedAttachTimesOut", "preAttachFailureRetiresWaiter",
            "cancellationRevokesBufferedConfirmation", "tokenCancellationRevokesBufferedConfirmation", "beginRetiresWaiter",
            "secondWaitRetiresFirst", "cancellationRetiresWaiter",
        ])
    func waiterRetirement(scenario: String) async throws {
        let center = SessionRecoveryConfirmationCenter()
        let id = TerminalSessionID.generate()
        center.begin(id, daemonPID: 42, createdEpoch: 100)
        switch scenario {
        case "startedAttachTimesOut":
            center.didStartAttach(id)
            #expect(await center.wait(for: id, timeout: .milliseconds(10)) == false)
        case "neverStartedAttachTimesOut":
            #expect(await center.wait(for: id, startupTimeout: .milliseconds(10)) == false)
            #expect(center.expectationToken(for: id) == nil)
        case "cancellationRevokesBufferedConfirmation", "tokenCancellationRevokesBufferedConfirmation":
            let token = try #require(center.expectationToken(for: id))
            try confirm(center, id: id, daemonPID: 42, createdEpoch: 100)
            if scenario == "tokenCancellationRevokesBufferedConfirmation" {
                center.cancel(id, expectationToken: token)
            } else {
                center.cancel(id)
            }
            #expect(await center.wait(for: id, timeout: .milliseconds(10)) == false)
        case "preAttachFailureRetiresWaiter", "beginRetiresWaiter", "cancellationRetiresWaiter":
            let task = Task { await center.wait(for: id, timeout: .seconds(10)) }
            await drainMainQueue(rounds: 1)
            switch scenario {
            case "preAttachFailureRetiresWaiter": center.cancel(id)
            case "beginRetiresWaiter": center.begin(id, daemonPID: 42, createdEpoch: 100)
            default: task.cancel()
            }
            #expect(await task.value == false)
        case "secondWaitRetiresFirst":
            let first = Task { await center.wait(for: id, timeout: .seconds(10)) }
            await drainMainQueue(rounds: 1)
            let second = Task { await center.wait(for: id, timeout: .seconds(10)) }
            await drainMainQueue(rounds: 1)
            let watchdog = DispatchWorkItem {
                Issue.record("second wait did not retire the installed first waiter")
                center.cancel(id)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: watchdog)
            #expect(await first.value == false)
            watchdog.cancel()
            try confirm(center, id: id, daemonPID: 42, createdEpoch: 100)
            #expect(await second.value)
        default: Issue.record("Unknown scenario: \(scenario)")
        }
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
        await drainMainQueue(rounds: 1)

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

    @Test("replacement daemon does not confirm recovery")
    func replacementDoesNotConfirm() async throws {
        let center = SessionRecoveryConfirmationCenter()
        let id = TerminalSessionID.generate()
        center.begin(id, daemonPID: 42, createdEpoch: 100)
        let task = Task { await center.wait(for: id, timeout: .seconds(10)) }
        await drainMainQueue(rounds: 1)

        try confirm(center, id: id, daemonPID: 99, createdEpoch: 101)

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
