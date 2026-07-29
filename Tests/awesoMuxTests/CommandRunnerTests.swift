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

private enum TestSpawnError: Error {
    case failed
}

private final class SpawnObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var invoked = false

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
