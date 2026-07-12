import Foundation
@testable import awesoMux

// MARK: - StubCommandRunner

/// Scriptable `CommandRunner` test double. Rules match on `(executable, args)`
/// (a `nil` field is a wildcard); the first matching rule wins, falling back to
/// `defaultOutcome`. Every call is recorded for assertion.
final class StubCommandRunner: CommandRunner, @unchecked Sendable {
    struct Invocation: Equatable, Sendable {
        var executable: String
        var args: [String]
        var env: [String: String]
        var cwd: URL?
    }

    enum Outcome: Sendable {
        case result(CommandResult)
        case failure(CommandRunnerError)
    }

    private struct Rule {
        var executable: String?
        var args: [String]?
        var outcome: Outcome
    }

    private let lock = NSLock()
    private var rules: [Rule] = []
    private var recorded: [Invocation] = []
    private var defaultOutcomeStorage: Outcome =
        .result(CommandResult(exitCode: 0, stdout: "", stderr: ""))

    var defaultOutcome: Outcome {
        get { lock.lock(); defer { lock.unlock() }; return defaultOutcomeStorage }
        set { lock.lock(); defaultOutcomeStorage = newValue; lock.unlock() }
    }

    var invocations: [Invocation] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func stub(executable: String? = nil, args: [String]? = nil, result: CommandResult) {
        lock.lock()
        rules.append(Rule(executable: executable, args: args, outcome: .result(result)))
        lock.unlock()
    }

    func stub(executable: String? = nil, args: [String]? = nil, failure: CommandRunnerError) {
        lock.lock()
        rules.append(Rule(executable: executable, args: args, outcome: .failure(failure)))
        lock.unlock()
    }

    func run(
        executable: String,
        args: [String],
        env: [String: String],
        cwd: URL?
    ) async throws -> CommandResult {
        let outcome: Outcome = lock.withLock {
            recorded.append(Invocation(executable: executable, args: args, env: env, cwd: cwd))
            return rules.first {
                ($0.executable == nil || $0.executable == executable)
                    && ($0.args == nil || $0.args == args)
            }?.outcome ?? defaultOutcomeStorage
        }

        switch outcome {
        case .result(let result):
            return result
        case .failure(let error):
            throw error
        }
    }
}
