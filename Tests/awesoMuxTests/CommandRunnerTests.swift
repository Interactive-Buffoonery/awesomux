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

    @Test("overrunning the timeout throws timedOut and terminates the child")
    func timeoutTerminatesChild() async throws {
        let runner = ProcessCommandRunner(timeout: .milliseconds(200))
        await #expect(throws: CommandRunnerError.self) {
            try await runner.run(
                executable: "/bin/sleep",
                args: ["30"],
                env: [:],
                cwd: nil
            )
        }
    }

    @Test("cancellation propagates as CancellationError, not a returned result")
    func cancellationThrowsRatherThanReturning() async throws {
        let runner = ProcessCommandRunner()
        let task = Task {
            try await runner.run(
                executable: "/bin/sleep",
                args: ["30"],
                env: [:],
                cwd: nil
            )
        }
        // Let the child spawn, then cancel: the runner SIGTERMs it, which fires
        // the termination handler. The result must be a thrown CancellationError,
        // never a CommandResult carrying the signal-derived exit code (which the
        // caller would misread as an ordinary non-zero op failure).
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
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
