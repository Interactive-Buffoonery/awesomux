import AwesoMuxTestSupport
import Darwin
import Foundation
import Testing
@testable import awesoMux

@Suite("ProcessCommandRunner")
struct ProcessCommandRunnerTests {
    @Test("clean exit returns stdout and a zero exit code")
    func cleanExitCapturesStdout() async throws {
        let runner = ProcessCommandRunner()
        let result = try await runner.run(
            executable: "/bin/echo",
            args: ["hello", "world"],
            env: [:],
            cwd: nil
        )
        #expect(result.exitCode == 0)
        #expect(result.isSuccess)
        #expect(result.stdout == "hello world\n")
        #expect(result.stderr.isEmpty)
    }

    @Test("bare executable names resolve through the explicit PATH")
    func bareExecutableResolvesThroughPath() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "awesomux-command-runner-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appending(path: "path-tool")
        try Self.writeExecutable(
            at: executable,
            body: "#!/bin/sh\nprintf 'resolved:%s' \"$1\"\n"
        )

        let runner = ProcessCommandRunner(defaultPath: directory.path)
        let result = try await runner.run(
            executable: "path-tool",
            args: ["ok"],
            env: [:],
            cwd: nil
        )

        #expect(result.stdout == "resolved:ok")
    }

    @Test("tilde path entries resolve before spawning")
    func tildePathEntriesResolve() async throws {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "awesomux-command-runner-home-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: home) }
        let localBin = home.appending(path: ".local/bin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: localBin, withIntermediateDirectories: true)

        let toolName = "awesomux-command-runner-\(UUID().uuidString)"
        let executable = localBin.appending(path: toolName)
        try Self.writeExecutable(
            at: executable,
            body: "#!/bin/sh\nprintf 'tilde-path'\n"
        )

        let runner = ProcessCommandRunner(defaultPath: "~/.local/bin", homeDirectoryURL: home)
        let result = try await runner.run(
            executable: toolName,
            args: [],
            env: [:],
            cwd: nil
        )

        #expect(result.stdout == "tilde-path")
    }

    @Test("non-zero exit is a returned result, not a thrown error")
    func nonZeroExitIsReturned() async throws {
        let runner = ProcessCommandRunner()
        let result = try await runner.run(
            executable: "/usr/bin/false",
            args: [],
            env: [:],
            cwd: nil
        )
        #expect(result.exitCode != 0)
        #expect(!result.isSuccess)
    }

    @Test("non-zero exit surfaces stderr verbatim")
    func nonZeroExitSurfacesStderr() async throws {
        let runner = ProcessCommandRunner()
        // `sh -c` exits non-zero after writing to stderr; the runner execs sh
        // directly (the runner itself never invokes a shell).
        let result = try await runner.run(
            executable: "/bin/sh",
            args: ["-c", "echo boom 1>&2; exit 3"],
            env: [:],
            cwd: nil
        )
        #expect(result.exitCode == 3)
        #expect(result.stderr == "boom\n")
        #expect(result.stdout.isEmpty)
    }

    @Test("spawn ENOENT is a distinct executableNotFound error")
    func missingExecutableThrowsExecutableNotFound() async throws {
        let runner = ProcessCommandRunner()
        let missing = "/no/such/binary-\(UUID().uuidString)"
        await #expect(throws: CommandRunnerError.executableNotFound(missing)) {
            try await runner.run(executable: missing, args: [], env: [:], cwd: nil)
        }
    }

    @Test("missing bare executable throws executableNotFound with the requested name")
    func missingBareExecutableThrowsRequestedName() async throws {
        let runner = ProcessCommandRunner(defaultPath: "/no/such/path")
        let missing = "missing-tool-\(UUID().uuidString)"
        await #expect(throws: CommandRunnerError.executableNotFound(missing)) {
            try await runner.run(executable: missing, args: [], env: [:], cwd: nil)
        }
    }

    @Test("a pre-cancelled run never spawns")
    @MainActor
    func preCancelledRunDoesNotSpawn() async throws {
        let startGate = AsyncGate()
        let spawnObservation = SpawnObservation()
        let runner = ProcessCommandRunner(spawn: { process in
            spawnObservation.record()
            try process.run()
        })
        let run = Task {
            await startGate.wait()
            return try await runner.run(
                executable: "/usr/bin/true", args: [], env: [:], cwd: nil)
        }

        #expect(await waitUntil { startGate.waiterCount == 1 })
        run.cancel()
        startGate.open()

        await #expect(throws: CancellationError.self) {
            _ = try await run.value
        }
        #expect(!spawnObservation.wasInvoked)
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

    @Test("timeout is not armed until spawning succeeds")
    func timeoutStartsAfterSpawn() async throws {
        let delays = ProcessDelayGate()
        let spawnGate = BlockingSpawnGate()
        defer {
            spawnGate.open()
            delays.advanceOneCycle()
        }
        let runner = ProcessCommandRunner(
            timeout: .seconds(1),
            delay: { duration in try await delays.wait(for: duration) },
            spawn: { process in try spawnGate.run(process) }
        )

        let run = Task.detached {
            try await runner.run(executable: "/usr/bin/true", args: [], env: [:], cwd: nil)
        }

        await spawnGate.waitUntilStarted()
        #expect(delays.requestedDurations.isEmpty)

        spawnGate.open()
        let result = try await run.value
        #expect(result.isSuccess)
    }

    @Test("a failed spawn does not arm the timeout or hang pipe drains")
    func failedSpawnDoesNotArmTimeout() async throws {
        let delays = ProcessDelayGate()
        defer { delays.advanceOneCycle() }
        let runner = ProcessCommandRunner(
            timeout: .seconds(1),
            delay: { duration in try await delays.wait(for: duration) },
            spawn: { _ in throw TestSpawnError.failed }
        )

        do {
            _ = try await runner.run(executable: "/usr/bin/true", args: [], env: [:], cwd: nil)
            Issue.record("Expected spawnFailed")
        } catch CommandRunnerError.spawnFailed(let executable, _) {
            #expect(executable == "/usr/bin/true")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(delays.requestedDurations.isEmpty)
    }

    @Test("cancellation racing a failed spawn stays cancellation")
    func cancelledFailedSpawnThrowsCancellation() async throws {
        let delays = ProcessDelayGate()
        let spawnGate = BlockingSpawnGate()
        defer {
            spawnGate.open()
            delays.advanceOneCycle()
        }
        let runner = ProcessCommandRunner(
            timeout: .seconds(60),
            delay: { duration in try await delays.wait(for: duration) },
            spawn: { _ in try spawnGate.fail(TestSpawnError.failed) }
        )
        let run = Task.detached {
            try await runner.run(executable: "/usr/bin/true", args: [], env: [:], cwd: nil)
        }

        await spawnGate.waitUntilStarted()
        run.cancel()
        #expect(delays.requestedDurations.isEmpty)
        spawnGate.open()

        await #expect(throws: CancellationError.self) {
            _ = try await run.value
        }
        #expect(!delays.requestedDurations.contains(.seconds(60)))
    }

    @Test("overrunning the timeout escalates from SIGTERM to SIGKILL")
    func timeoutTerminatesChild() async throws {
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
    }

    @Test("cancellation during spawn terminates the child after spawn succeeds")
    func cancellationDuringSpawnTerminatesChild() async throws {
        let delays = ProcessDelayGate()
        let spawnGate = BlockingSpawnGate()
        defer {
            spawnGate.open()
            delays.advanceOneCycle()
        }
        let runner = ProcessCommandRunner(
            timeout: .seconds(60),
            delay: { duration in try await delays.wait(for: duration) },
            spawn: { process in try spawnGate.run(process) }
        )
        let run = Task.detached {
            try await runner.run(executable: "/bin/sleep", args: ["30"], env: [:], cwd: nil)
        }

        await spawnGate.waitUntilStarted()
        run.cancel()
        #expect(delays.requestedDurations.isEmpty)
        spawnGate.open()

        await #expect(throws: CancellationError.self) {
            _ = try await run.value
        }
        #expect(!delays.requestedDurations.contains(.seconds(60)))
    }

    @Test("cancellation escalates to SIGKILL and throws CancellationError")
    func cancellationThrowsRatherThanReturning() async throws {
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

    @Test("cancelled test delays resume without manual advancement")
    func cancelledTestDelayResumes() async {
        let delays = ProcessDelayGate()
        let wait = Task {
            try await delays.wait(for: .seconds(1))
        }

        await delays.waitForRequestCount(1)
        wait.cancel()

        await #expect(throws: CancellationError.self) {
            try await wait.value
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

    @Test("cancellation lets the child flush output during its TERM grace")
    func cancellationPreservesOutputDuringGrace() async throws {
        let ready = Self.temporaryReadyFile()
        let cleaned = Self.temporaryReadyFile()
        defer {
            try? FileManager.default.removeItem(at: ready)
            try? FileManager.default.removeItem(at: cleaned)
        }
        let observation = SpawnObservation()
        defer { observation.forceKill() }
        let runner = ProcessCommandRunner(spawn: { try observation.run($0) })
        let watchdog = DispatchWorkItem { observation.forceKill() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: watchdog)
        defer { watchdog.cancel() }
        let run = Task.detached {
            try await runner.run(
                executable: "/bin/sh",
                args: [
                    "-c",
                    "trap 'i=0; while [ $i -lt 10000 ]; do echo cleanup; i=$((i+1)); done; : > \"$2\"; exit 0' TERM; : > \"$1\"; while :; do :; done",
                    "sh", ready.path, cleaned.path,
                ],
                env: [:], cwd: nil
            )
        }
        #expect(await Self.waitForFile(ready))
        run.cancel()
        await #expect(throws: CancellationError.self) { try await run.value }
        #expect(FileManager.default.fileExists(atPath: cleaned.path), "closing readers early interrupts TERM cleanup with SIGPIPE")
    }

    @Test("delayed exit notification does not time out an already drained command")
    func delayedExitNotificationPreservesSuccess() async throws {
        let runner = ProcessCommandRunner(
            timeout: .milliseconds(500),
            spawn: { process in
                let handler = process.terminationHandler
                process.terminationHandler = { child in
                    // Delay Foundation's notification beyond the deadline while
                    // leaving the real child-exit and pipe-EOF signals intact.
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                        handler?(child)
                    }
                }
                try process.run()
            }
        )
        let result = try await runner.run(executable: "/bin/echo", args: ["done"], env: [:], cwd: nil)
        #expect(result.exitCode == 0)
        #expect(result.stdout == "done\n")
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

    @Test("caller env keys reach the child and a default PATH is always present")
    func environmentCarriesCallerKeysAndPath() async throws {
        let runner = ProcessCommandRunner()
        let result = try await runner.run(
            executable: "/bin/sh",
            args: ["-c", "printf '%s\\n%s' \"$CODEX_HOME\" \"$PATH\""],
            env: ["CODEX_HOME": "/tmp/codex-home"],
            cwd: nil
        )
        let lines = result.stdout.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.first == "/tmp/codex-home")
        #expect(result.stdout.contains("/usr/bin"))
    }

    @Test("resolveExecutable finds a bare name present on the search path")
    func resolveExecutableFindsBareNameOnPath() throws {
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
    }

    @Test("resolveExecutable returns nil for a bare name absent from the search path")
    func resolveExecutableMissesBareNameOffPath() {
        let resolved = ProcessCommandRunner.resolveExecutable(
            "codex-\(UUID().uuidString)",
            searchPath: "/no/such/path",
            homeDirectoryURL: FileManager.default.homeDirectoryForCurrentUser
        )
        #expect(resolved == nil)
    }

    @Test("resolveExecutable tilde-expands a bare name search path entry")
    func resolveExecutableExpandsTildeSearchPath() throws {
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

private enum TestSpawnError: Error {
    case failed
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

private final class BlockingSpawnGate: @unchecked Sendable {
    private let permit = DispatchSemaphore(value: 0)
    private let startedSignal = DispatchSemaphore(value: 0)

    func waitUntilStarted() async {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                self.startedSignal.wait()
                continuation.resume()
            }
        }
    }

    func run(_ process: Process) throws {
        waitForPermit()
        try process.run()
    }

    func fail(_ error: Error) throws {
        waitForPermit()
        throw error
    }

    func open() {
        permit.signal()
    }

    private func waitForPermit() {
        startedSignal.signal()
        permit.wait()
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

@Suite("StubCommandRunner")
struct StubCommandRunnerTests {
    @Test("returns the canned result for a matching executable and args")
    func returnsCannedResult() async throws {
        let runner = StubCommandRunner()
        runner.stub(
            executable: "/usr/bin/claude",
            args: ["plugin", "list", "--json"],
            result: CommandResult(exitCode: 0, stdout: "{}", stderr: "")
        )

        let result = try await runner.run(
            executable: "/usr/bin/claude",
            args: ["plugin", "list", "--json"],
            env: ["PATH": "/usr/bin"],
            cwd: nil
        )
        #expect(result.stdout == "{}")
    }

    @Test("throws the canned spawn failure")
    func throwsCannedFailure() async throws {
        let runner = StubCommandRunner()
        runner.stub(executable: "/usr/bin/claude", failure: .executableNotFound("/usr/bin/claude"))

        await #expect(throws: CommandRunnerError.executableNotFound("/usr/bin/claude")) {
            try await runner.run(executable: "/usr/bin/claude", args: [], env: [:], cwd: nil)
        }
    }

    @Test("records every invocation in order")
    func recordsInvocations() async throws {
        let runner = StubCommandRunner()
        _ = try await runner.run(executable: "/a", args: ["one"], env: [:], cwd: nil)
        _ = try await runner.run(
            executable: "/b",
            args: ["two"],
            env: ["K": "V"],
            cwd: URL(fileURLWithPath: "/tmp")
        )

        let invocations = runner.invocations
        #expect(invocations.count == 2)
        #expect(invocations[0] == StubCommandRunner.Invocation(
            executable: "/a", args: ["one"], env: [:], cwd: nil
        ))
        #expect(invocations[1].executable == "/b")
        #expect(invocations[1].env == ["K": "V"])
        #expect(invocations[1].cwd == URL(fileURLWithPath: "/tmp"))
    }

    @Test("falls back to the default outcome when no rule matches")
    func fallsBackToDefault() async throws {
        let runner = StubCommandRunner()
        runner.defaultOutcome = .result(CommandResult(exitCode: 7, stdout: "x", stderr: "y"))
        let result = try await runner.run(executable: "/unmatched", args: [], env: [:], cwd: nil)
        #expect(result.exitCode == 7)
    }
}
