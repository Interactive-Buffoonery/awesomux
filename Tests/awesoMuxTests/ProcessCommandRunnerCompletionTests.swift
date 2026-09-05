import AwesoMuxTestSupport
import Foundation
import Testing
@testable import awesoMux

extension ProcessCommandRunnerTests {
    @Test("missing exit callback preserves a completed command's output and status", arguments: [0, 7])
    func missingExitCallbackPreservesResult(exitCode: Int32) async throws {
        let notification = WithheldTerminationNotification()
        defer { notification.deliver() }
        let completed = EventRecorder<Void>()
        let runner = ProcessCommandRunner(timeout: .seconds(1), spawn: { try notification.spawn($0) })
        let run = Task.detached {
            let result = try await runner.run(
                executable: "/bin/sh",
                args: ["-c", "printf output; printf error >&2; exit \(exitCode)"],
                env: [:], cwd: nil
            )
            await completed.record(())
            return result
        }

        let finished = await completed.waitForCount(1, deadline: .seconds(5))
        #expect(finished, "the deadline must release a completed command without its callback")
        // Release the callback even on failure so a regression cannot strand the test task.
        notification.deliver()
        let result = try await run.value
        #expect(result.exitCode == exitCode)
        #expect(result.stdout == "output")
        #expect(result.stderr == "error")
    }

    @Test("cancellation releases an exited command without its callback")
    func cancellationWithoutExitCallbackCompletes() async throws {
        let notification = WithheldTerminationNotification()
        defer { notification.deliver() }
        let completed = EventRecorder<Void>()
        let runner = ProcessCommandRunner(timeout: .seconds(60), spawn: { try notification.spawn($0) })
        let run = Task.detached {
            let result: Result<CommandResult, Error>
            do {
                result = .success(try await runner.run(executable: "/usr/bin/true", args: [], env: [:], cwd: nil))
            } catch {
                result = .failure(error)
            }
            await completed.record(())
            return result
        }

        #expect(await waitUntilEventually { notification.hasExited })
        run.cancel()
        let finished = await completed.waitForCount(1, deadline: .seconds(3))
        #expect(finished, "cancellation must not wait for a missing exit callback")
        notification.deliver()
        let result = await run.value
        #expect(throws: CancellationError.self) { try result.get() }
    }

    @Test("termination escalation completes without the exit callback", arguments: [false, true])
    func escalationWithoutExitCallbackCompletes(cancel: Bool) async throws {
        let notification = WithheldTerminationNotification()
        defer { notification.deliver() }
        let ready = FileManager.default.temporaryDirectory.appending(path: "runner-escalation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: ready) }
        let completed = EventRecorder<Void>()
        let timeout: Duration = cancel ? .seconds(60) : .seconds(1)
        let runner = ProcessCommandRunner(timeout: timeout, spawn: { try notification.spawn($0) })
        let run = Task.detached {
            let result: Result<CommandResult, Error>
            do {
                result = .success(
                    try await runner.run(
                        executable: "/bin/sh",
                        // Finite lifetime also bounds fixture cleanup if escalation regresses.
                        args: ["-c", "trap '' TERM; : > \"$1\"; exec /bin/sleep 4", "sh", ready.path],
                        env: [:], cwd: nil
                    ))
            } catch {
                result = .failure(error)
            }
            await completed.record(())
            return result
        }

        #expect(await waitUntilEventually { FileManager.default.fileExists(atPath: ready.path) })
        if cancel { run.cancel() }
        let finished = await completed.waitForCount(1, deadline: .seconds(3))
        #expect(finished, "the end of the TERM grace must release the wait without a callback")
        notification.deliver()
        let result = await run.value
        if cancel {
            #expect(throws: CancellationError.self) { try result.get() }
        } else {
            #expect(throws: CommandRunnerError.timedOut("/bin/sh", timeout)) { try result.get() }
        }
    }
}

/// Holds only the runner's notification; Foundation still records real child exit.
/// Delivery can be enabled before exit so failure cleanup also works for a live child.
private final class WithheldTerminationNotification: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable () -> Void)?
    private var exited = false
    private var deliveryEnabled = false

    var hasExited: Bool { lock.withLock { exited } }

    func spawn(_ process: Process) throws {
        let handler = process.terminationHandler
        process.terminationHandler = { child in
            let pending: (@Sendable () -> Void)? = self.lock.withLock {
                self.exited = true
                let callback: @Sendable () -> Void = { handler?(child) }
                if self.deliveryEnabled { return callback }
                self.callback = callback
                return nil
            }
            pending?()
        }
        try process.run()
    }

    func deliver() {
        let pending = lock.withLock {
            deliveryEnabled = true
            let pending = callback
            callback = nil
            return pending
        }
        pending?()
    }
}
