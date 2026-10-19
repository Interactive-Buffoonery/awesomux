import AwesoMuxTestSupport
import Darwin
import Foundation
import Testing
@testable import awesoMux

@Suite("ProcessCommandRunner")
struct ProcessCommandRunnerTests {

    @Test(arguments: [false, true])
    func missingExecutablePreservesRequestedName(bare: Bool) async throws {
        let runner = ProcessCommandRunner(defaultPath: "/no/such/path")
        let missing = bare ? "missing-tool-\(UUID().uuidString)" : "/no/such/binary-\(UUID().uuidString)"
        await #expect(throws: CommandRunnerError.executableNotFound(missing)) {
            try await runner.run(executable: missing, args: [], env: [:], cwd: nil)
        }
    }

    @Test("cancellation while spawn is queued never launches the command")
    func cancellationWhileSpawnIsQueuedDoesNotSpawn() async throws {
        let scheduleGate = ScheduledOperationGate()
        let spawnObservation = SpawnObservation()
        let runner = ProcessCommandRunner(
            schedule: { scheduleGate.schedule($0) },
            spawn: { process in
                spawnObservation.record()
                try process.run()
            }
        )
        let run = Task.detached {
            try await runner.run(executable: "/usr/bin/true", args: [], env: [:], cwd: nil)
        }

        #expect(await waitUntil { scheduleGate.hasOperation })
        run.cancel()
        scheduleGate.run()

        await #expect(throws: CancellationError.self) {
            _ = try await run.value
        }
        #expect(!spawnObservation.wasInvoked)
    }

    enum InterruptedChildCase: String, CaseIterable {
        case timeoutTerminatesChild
        case cancellationThrowsRatherThanReturning
    }

    @Test(arguments: InterruptedChildCase.allCases)
    func interruptedChild(_ scenario: InterruptedChildCase) async throws {
        switch scenario {
        case .timeoutTerminatesChild:
            let delays = ProcessDelayGate()
            defer { delays.advanceOneCycle() }
            let ready = Self.temporaryReadyFile()
            defer { try? FileManager.default.removeItem(at: ready) }
            let completed = EventRecorder<Void>()
            let spawnObservation = SpawnObservation()
            defer { spawnObservation.forceKill() }
            let runner = ProcessCommandRunner(
                timeout: .seconds(1),
                delay: { duration in try await delays.wait(for: duration) },
                spawn: { process in try spawnObservation.run(process) }
            )
            let run = Task.detached {
                do {
                    let result = try await runner.run(
                        executable: "/bin/sh",
                        args: Self.termIgnoringSleepArguments(ready: ready),
                        env: [:],
                        cwd: nil
                    )
                    await completed.record(())
                    return result
                } catch {
                    await completed.record(())
                    throw error
                }
            }

            await delays.waitForRequestCount(1)
            #expect(await Self.waitForFile(ready))
            delays.advanceOneCycle()
            await delays.waitForRequestCount(2)
            #expect(delays.requestedDurations == [.seconds(1), .seconds(1)])
            #expect(await completed.values.isEmpty)

            delays.advanceOneCycle()
            let didComplete = await completed.waitForCount(1, deadline: .seconds(10))
            if !didComplete { spawnObservation.forceKill() }
            #expect(didComplete, "SIGKILL escalation did not finish the child")
            await #expect(throws: CommandRunnerError.timedOut("/bin/sh", .seconds(1))) {
                _ = try await run.value
            }
        case .cancellationThrowsRatherThanReturning:
            let delays = ProcessDelayGate()
            defer { delays.advanceOneCycle() }
            let ready = Self.temporaryReadyFile()
            defer { try? FileManager.default.removeItem(at: ready) }
            let completed = EventRecorder<Void>()
            let spawnObservation = SpawnObservation()
            defer { spawnObservation.forceKill() }
            let runner = ProcessCommandRunner(
                timeout: .seconds(60),
                delay: { duration in try await delays.wait(for: duration) },
                spawn: { process in try spawnObservation.run(process) }
            )
            let run = Task.detached {
                do {
                    let result = try await runner.run(
                        executable: "/bin/sh",
                        args: Self.termIgnoringSleepArguments(ready: ready),
                        env: [:],
                        cwd: nil
                    )
                    await completed.record(())
                    return result
                } catch {
                    await completed.record(())
                    throw error
                }
            }

            await delays.waitForRequestCount(1)
            #expect(await Self.waitForFile(ready))
            run.cancel()
            await delays.waitForRequestCount(2)
            #expect(delays.requestedDurations == [.seconds(60), .seconds(1)])
            #expect(await completed.values.isEmpty)

            delays.advanceOneCycle()
            let didComplete = await completed.waitForCount(1, deadline: .seconds(10))
            if !didComplete { spawnObservation.forceKill() }
            #expect(didComplete, "cancellation SIGKILL escalation did not finish the child")
            await #expect(throws: CancellationError.self) {
                _ = try await run.value
            }
        }
    }

    @Test("inherited pipe writers remain bounded after parent exit", arguments: [false, true], [false, true])
    func inheritedWritersAreBounded(stderr: Bool, cancel: Bool) async throws {
        let fixture = try InheritedWriterFixture()
        defer { fixture.cleanup() }
        let observation = SpawnObservation()
        let delays = ProcessDelayGate()
        defer { delays.advanceOneCycle() }
        let completed = EventRecorder<Void>()
        let runner = ProcessCommandRunner(
            timeout: .seconds(60),
            delay: { try await delays.wait(for: $0) },
            spawn: { process in
                fixture.attach(to: process)
                try observation.run(process)
            }
        )
        let run = Task.detached {
            let result: Result<CommandResult, Error>
            do {
                result = .success(
                    try await runner.run(
                        executable: "/bin/sh",
                        args: fixture.arguments(stderr: stderr),
                        env: [:], cwd: nil
                    ))
            } catch {
                result = .failure(error)
            }
            await completed.record(())
            return result
        }
        // Independent of Swift task cancellation and the injected clock: a
        // broken runner cannot keep this fixture's pipe writer alive forever.
        let watchdog = DispatchWorkItem { fixture.cleanup() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: watchdog)
        defer { watchdog.cancel() }

        let exited = await waitUntilEventually { observation.hasExited }
        #expect(exited)
        guard exited else { return }
        #expect(await Self.waitForFile(fixture.readyFile))
        #expect(await completed.values.isEmpty)
        #expect(fixture.writerIsAlive)
        if cancel {
            run.cancel()
        } else {
            #expect(await waitUntil { !delays.requestedDurations.isEmpty })
            delays.advanceOneCycle()
        }
        let finished = await completed.waitForCount(1, deadline: .seconds(2))
        #expect(finished, "run must finish while the inherited writer is still alive")
        #expect(fixture.writerIsAlive)
        guard finished else { return }
        let result = await run.value
        if cancel {
            #expect(throws: CancellationError.self) { try result.get() }
        } else {
            #expect(throws: CommandRunnerError.timedOut("/bin/sh", .seconds(60))) { try result.get() }
        }
        fixture.cleanup()
        fixture.cleanup()
        #expect(await Self.waitForFile(fixture.exitedFile), "fixture cleanup must release its inherited writer through EOF")
    }

    @Test("withheld exit notification preserves a drained command's output and status", arguments: [0, 7])
    func withheldExitNotificationPreservesSuccess(exitCode: Int32) async throws {
        let notification = WithheldTerminationNotification()
        let delays = ProcessDelayGate()
        defer {
            notification.deliver()
            delays.advanceOneCycle()
        }
        let drained = EventRecorder<Void>()
        let completed = EventRecorder<Result<CommandResult, Error>>()
        let runner = ProcessCommandRunner(
            timeout: .seconds(1),
            delay: { try await delays.wait(for: $0) },
            spawn: { try notification.spawn($0) },
            readOutput: { reader in
                let output = await reader.readToEnd()
                await drained.record(())
                return output
            }
        )
        let run = Task.detached {
            do {
                let result = try await runner.run(
                    executable: "/bin/sh",
                    args: ["-c", "printf output; printf error >&2; exit \(exitCode)"],
                    env: [:], cwd: nil
                )
                await completed.record(.success(result))
            } catch {
                await completed.record(.failure(error))
            }
        }

        #expect(await waitUntilEventually { notification.hasExited })
        #expect(await drained.waitForCount(2, deadline: .seconds(10)))
        #expect(await waitUntil { !delays.requestedDurations.isEmpty })
        #expect(delays.requestedDurations == [.seconds(1)])
        #expect(await completed.values.isEmpty)
        delays.advanceOneCycle()
        #expect(
            await completed.waitForCount(1, deadline: .seconds(5)),
            "the deadline must release a drained command without its callback"
        )

        // Failure cleanup releases the real callback and joins the task.
        notification.deliver()
        delays.advanceOneCycle()
        await run.value
        let result = try #require(await completed.values.first).get()
        #expect(result.exitCode == exitCode)
        #expect(result.stdout == "output")
        #expect(result.stderr == "error")
    }

    @Test("output arriving after parent exit is collected before the deadline")
    func collectsLateOutput() async throws {
        let runner = ProcessCommandRunner(timeout: .seconds(10))
        let result = try await runner.run(
            executable: "/bin/sh",
            args: ["-c", "( /bin/sleep 0.1; printf late-out; printf late-err >&2 ) & printf early; exit 0"],
            env: [:], cwd: nil
        )
        #expect(result.exitCode == 0)
        #expect(result.stdout == "earlylate-out")
        #expect(result.stderr == "late-err")
    }

    @Test("both streams retain complete output larger than pipe capacity")
    func completeLargeOutput() async throws {
        let runner = ProcessCommandRunner(timeout: .seconds(10))
        let result = try await runner.run(
            executable: "/bin/sh",
            args: ["-c", "i=0; while [ $i -lt 20000 ]; do printf 'stdout line\\n'; printf 'stderr line\\n' >&2; i=$((i+1)); done"],
            env: [:], cwd: nil
        )
        #expect(result.exitCode == 0)
        #expect(result.stdout == String(repeating: "stdout line\n", count: 20000))
        #expect(result.stderr == String(repeating: "stderr line\n", count: 20000))
    }

    enum ExecutableResolutionCase: String, CaseIterable {
        case resolveExecutableFindsBareNameOnPath
        case resolveExecutableMissesBareNameOffPath
        case resolveExecutableExpandsTildeSearchPath
    }

    @Test(arguments: ExecutableResolutionCase.allCases)
    func executableResolution(_ scenario: ExecutableResolutionCase) throws {
        switch scenario {
        case .resolveExecutableFindsBareNameOnPath:
            let directory = FileManager.default.temporaryDirectory
                .appending(path: "awesomux-resolve-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let executable = directory.appending(path: "codex")
            try Self.writeExecutable(at: executable, body: "#!/bin/sh\n")

            let resolved = ProcessCommandRunner.resolveExecutable(
                "codex",
                searchPath: directory.path,
                homeDirectoryURL: FileManager.default.homeDirectoryForCurrentUser
            )
            #expect(resolved?.path == executable.path)
        case .resolveExecutableMissesBareNameOffPath:
            let resolved = ProcessCommandRunner.resolveExecutable(
                "codex-\(UUID().uuidString)",
                searchPath: "/no/such/path",
                homeDirectoryURL: FileManager.default.homeDirectoryForCurrentUser
            )
            #expect(resolved == nil)
        case .resolveExecutableExpandsTildeSearchPath:
            let home = FileManager.default.temporaryDirectory
                .appending(path: "awesomux-resolve-home-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: home) }
            let localBin = home.appending(path: ".local/bin", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: localBin, withIntermediateDirectories: true)
            let executable = localBin.appending(path: "codex")
            try Self.writeExecutable(at: executable, body: "#!/bin/sh\n")

            let resolved = ProcessCommandRunner.resolveExecutable(
                "codex",
                searchPath: "~/.local/bin",
                homeDirectoryURL: home
            )
            #expect(resolved?.path == executable.path)
        }
    }

    private static func writeExecutable(at url: URL, body: String) throws {
        _ = FileManager.default.createFile(atPath: url.path, contents: Data(body.utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private static func temporaryReadyFile() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "awesomux-command-ready-\(UUID().uuidString)")
    }

    private static func termIgnoringSleepArguments(ready: URL) -> [String] {
        // trap '' TERM sets SIG_IGN, which survives exec and forces SIGKILL escalation.
        ["-c", "trap '' TERM; : > \"$1\"; exec /bin/sleep 300", "sh", ready.path]
    }

    private static func waitForFile(_ url: URL) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while clock.now < deadline {
            if FileManager.default.fileExists(atPath: url.path) { return true }
            try? await clock.sleep(for: .milliseconds(20))
        }
        return FileManager.default.fileExists(atPath: url.path)
    }
}

/// The orphan keeps an inherited output pipe open while reading a fixture-owned
/// input pipe. Closing our writer releases it without signaling a reusable PID.
private final class InheritedWriterFixture: @unchecked Sendable {
    let directory: URL
    let readyFile: URL
    let exitedFile: URL
    private let control = Pipe()
    private let lock = NSLock()
    private var cleaned = false

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "runner-writer-\(UUID().uuidString)")
        readyFile = directory.appending(path: "ready")
        exitedFile = directory.appending(path: "exited")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        cleanup()
        try? FileManager.default.removeItem(at: directory)
    }

    func attach(to process: Process) {
        process.standardInput = control
    }

    func arguments(stderr: Bool) -> [String] {
        let redirect = stderr ? "1>/dev/null" : "2>/dev/null"
        // Preserve stdin on fd 3 because the shell redirects a background job's
        // stdin to /dev/null. read is a builtin, so cleanup leaves no grandchild.
        let script = "exec 3<&0; (: > \"$1\"; IFS= read -r line <&3; : > \"$2\") \(redirect) & echo ready; exit 0"
        return ["-c", script, "sh", readyFile.path, exitedFile.path]
    }

    var writerIsAlive: Bool {
        FileManager.default.fileExists(atPath: readyFile.path)
            && !FileManager.default.fileExists(atPath: exitedFile.path)
    }

    func cleanup() {
        lock.withLock {
            guard !cleaned else { return }
            cleaned = true
            try? control.fileHandleForWriting.close()
        }
    }
}

private final class SpawnObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var invoked = false

    var hasExited: Bool {
        lock.withLock { process.map { $0.processIdentifier > 0 && !$0.isRunning } ?? false }
    }

    var wasInvoked: Bool {
        lock.withLock { invoked }
    }

    func record() {
        lock.withLock { invoked = true }
    }

    func run(_ process: Process) throws {
        lock.withLock {
            invoked = true
            self.process = process
        }
        try process.run()
    }

    func forceKill() {
        let process = lock.withLock { self.process }
        if let process, process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
    }
}

private final class ProcessDelayGate: @unchecked Sendable {
    private typealias DelayContinuation = CheckedContinuation<Void, Error>
    private typealias Continuation = CheckedContinuation<Void, Never>

    private let lock = NSLock()
    private var delayWaiters: [(id: UUID, continuation: DelayContinuation)] = []
    private var requestWaiters: [(count: Int, continuation: Continuation)] = []
    private var requests: [Duration] = []

    var requestedDurations: [Duration] {
        lock.withLock { requests }
    }

    func wait(for duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: DelayContinuation) in
                lock.lock()
                requests.append(duration)
                let ready = requestWaiters.filter { requests.count >= $0.count }
                requestWaiters.removeAll { requests.count >= $0.count }
                guard !Task.isCancelled else {
                    lock.unlock()
                    ready.forEach { $0.continuation.resume() }
                    continuation.resume(throwing: CancellationError())
                    return
                }
                delayWaiters.append((id, continuation))
                lock.unlock()
                ready.forEach { $0.continuation.resume() }
            }
        } onCancel: {
            let continuation: DelayContinuation? = lock.withLock {
                guard let index = delayWaiters.firstIndex(where: { $0.id == id }) else {
                    return nil
                }
                return delayWaiters.remove(at: index).continuation
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    func waitForRequestCount(_ count: Int) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            guard requests.count < count else {
                lock.unlock()
                continuation.resume()
                return
            }
            requestWaiters.append((count, continuation))
            lock.unlock()
        }
    }

    func advanceOneCycle() {
        let continuations = lock.withLock {
            let continuations = delayWaiters
            delayWaiters.removeAll()
            return continuations
        }
        continuations.forEach { $0.continuation.resume() }
    }
}

private final class ScheduledOperationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var operation: (@Sendable () -> Void)?

    var hasOperation: Bool {
        lock.withLock { operation != nil }
    }

    func schedule(_ operation: @escaping @Sendable () -> Void) {
        lock.withLock { self.operation = operation }
    }

    func run() {
        lock.withLock {
            let operation = self.operation
            self.operation = nil
            return operation
        }?()
    }
}
