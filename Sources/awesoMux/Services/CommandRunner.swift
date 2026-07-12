import Foundation

// MARK: - CommandResult

/// Outcome of a process that spawned and exited.
///
/// A non-zero `exitCode` is a *returned* result, not a thrown error. Per the
/// install contract (§3) a present binary that runs and exits non-zero is an
/// operation failure whose `stderr` the caller surfaces verbatim — categorically
/// different from the binary being absent, which surfaces as
/// `CommandRunnerError.executableNotFound`. Keeping the two on different channels
/// is what lets the consumer map CLI-absent → `Unsupported` without collapsing it
/// into a generic op failure.
struct CommandResult: Equatable, Sendable {
    var exitCode: Int32
    var stdout: String
    var stderr: String

    var isSuccess: Bool { exitCode == 0 }
}

// MARK: - CommandRunner

/// One-shot CLI execution for the `claude plugin …` / `codex plugin …` commands
/// the agent-status installer drives.
///
/// No shell is involved at any conforming layer: the executable is exec'd
/// directly, so arguments carry no quoting or injection surface. `env` is the
/// set of caller-supplied keys (always `PATH` for Claude, `CODEX_HOME` for
/// Codex, per contract §3); a conforming runner is free to seed a minimal base
/// environment but must not inherit the full process environment implicitly.
protocol CommandRunner: Sendable {
    func run(
        executable: String,
        args: [String],
        env: [String: String],
        cwd: URL?
    ) async throws -> CommandResult
}

// MARK: - CommandRunnerError

/// Failure modes that are *not* a clean spawn-and-exit.
///
/// The contract (§3) requires these to stay distinguishable from a non-zero exit
/// (which is a `CommandResult`, never an error): a missing binary is the
/// CLI-absent signal that maps to `Unsupported`, and must not be confused with a
/// present binary that spawned but exited non-zero.
enum CommandRunnerError: Error, Equatable, Sendable {
    /// Nothing executable exists at the given path (ENOENT). This is the
    /// CLI-absent signal → `Unsupported`.
    case executableNotFound(String)
    /// The path is executable but the spawn itself failed for another reason
    /// (permissions, fork failure). Kept distinct from a missing binary.
    case spawnFailed(String, reason: String)
    /// The process ran past its timeout and was terminated.
    case timedOut(String, Duration)
}
