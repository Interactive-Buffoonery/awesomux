import AwesoMuxCore
import Foundation

typealias GitRepositoryContext = AwesoMuxCore.GitRepositoryContext

enum GitRepositoryLocationFailure: Equatable, Sendable {
    case executableNotFound
    case spawnFailure
    case timedOut
    case outputTruncated
    case outputNotDrained
    case malformedOutput
}

enum GitRepositoryLocationOutcome: Equatable, Sendable {
    case located(GitRepositoryContext)
    case notRepository
    case bareRepository
    case failure(GitRepositoryLocationFailure)
}

protocol LocalGitCommandRunning: Sendable {
    func run(arguments: [String], inDirectory directory: URL) async -> BoundedCommandResult
}

struct BoundedLocalGitCommandRunner: LocalGitCommandRunning {
    private let runner: BoundedCommandRunner

    /// The environment every git invocation from awesoMux runs under.
    ///
    /// **Trust contract, stated rather than implied.** This is the same
    /// boundary the Path Bar's existing `git status` already stands on: the
    /// repository is the user's own, and its root was validated
    /// (`TerminalPathBarModel.validatedRepoRootPath`) before any subprocess was
    /// spawned against it. What this scrub removes is the set of variables that
    /// *retarget* git — a different repository, a different config file, a
    /// different helper binary — because those can be exported into a shell by
    /// something other than the user and would silently redirect a command the
    /// user believes is reading the repository in front of them. `GIT_DIR`,
    /// `GIT_WORK_TREE`, `GIT_INDEX_FILE`, `GIT_COMMON_DIR`, `GIT_CONFIG*`,
    /// `GIT_ALTERNATE_OBJECT_DIRECTORIES`, `GIT_SSH*`, `GIT_ASKPASS`, and every
    /// other `GIT_`-prefixed variable go, and the two that make a non-interactive
    /// run behave are set explicitly afterwards.
    ///
    /// What this deliberately does NOT do is neutralize the repository's own
    /// configured `clean`/`smudge` filters or `diff.textconv` entries. Those
    /// live in the checkout's config, they already run for the Path Bar's
    /// `git status`, and disabling them here would make the diff disagree with
    /// what the user's own `git diff` shows. The individual commands still pass
    /// `--no-ext-diff` / `--no-textconv` where a diff would otherwise shell out
    /// per file. This is a boundary awesoMux inherits, not one it widens.
    private static let scrubbedEnvironment = scrubbing(ProcessInfo.processInfo.environment)

    /// The scrub itself, as a pure function of `inherited` so it can be
    /// exercised without the process's own environment.
    ///
    /// Every command awesoMux runs through this type is a local read. A future
    /// caller that reaches the network — `fetch`, `push`, `clone` — has to
    /// revisit the `GIT_SSH_COMMAND` / `GIT_ASKPASS` removal, because those
    /// carry the user's own credential and agent wiring and a network command
    /// stripped of them fails or prompts instead of authenticating.
    static func scrubbing(_ inherited: [String: String]) -> [String: String] {
        var environment = inherited.filter { !$0.key.hasPrefix("GIT_") }
        // Trusted absolute dirs go FIRST so a relative or repo-local inherited
        // entry can't shadow a tool with an attacker-planted binary. A launched
        // `.app` inherits launchd's minimal PATH, not the user's shell PATH.
        let toolPaths = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        environment["PATH"] = environment["PATH"].map { "\(toolPaths):\($0)" } ?? toolPaths
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_PAGER"] = "cat"
        environment["PAGER"] = "cat"
        return environment
    }

    init(
        executableCandidates: [String] = ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"],
        timeout: Duration = .seconds(5),
        maxOutputBytes: Int = 512 * 1024
    ) {
        runner = BoundedCommandRunner(
            executableCandidates: executableCandidates,
            timeout: timeout,
            maxOutputBytes: maxOutputBytes,
            environment: Self.scrubbedEnvironment
        )
    }

    func run(arguments: [String], inDirectory directory: URL) async -> BoundedCommandResult {
        await runner.runDetailed(arguments: arguments, inDirectory: directory.path)
    }
}

struct LocalGitRepositoryLocator: Sendable {
    private let runner: any LocalGitCommandRunning

    init(runner: any LocalGitCommandRunning = BoundedLocalGitCommandRunner()) {
        self.runner = runner
    }

    func locate(startingAt startingURL: URL) async -> GitRepositoryLocationOutcome {
        guard var directory = nearestExistingDirectory(to: startingURL) else {
            return .notRepository
        }

        while true {
            let bareResult = await runner.run(
                arguments: ["rev-parse", "--is-bare-repository"],
                inDirectory: directory
            )
            switch bareResult {
            case .success(let data):
                guard let value = strictUTF8(data)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                    return .failure(.malformedOutput)
                }
                if value == "true" {
                    return .bareRepository
                }
                guard value == "false" else {
                    return .failure(.malformedOutput)
                }
                break
            case .nonZeroExit:
                let parent = directory.deletingLastPathComponent()
                guard parent.path != directory.path else {
                    return .notRepository
                }
                directory = parent
                continue
            default:
                return .failure(mapFailure(bareResult))
            }
            break
        }

        let contextResult = await runner.run(
            arguments: [
                "rev-parse",
                "--path-format=absolute",
                "--show-toplevel",
                "--git-common-dir",
            ],
            inDirectory: directory
        )
        switch contextResult {
        case .success(let data):
            guard let output = strictUTF8(data) else {
                return .failure(.malformedOutput)
            }
            let lines = output.split(separator: "\n", omittingEmptySubsequences: true)
            guard lines.count == 2 else {
                return .failure(.malformedOutput)
            }
            let topLevel = canonicalURL(String(lines[0]))
            let commonDirectory = canonicalURL(String(lines[1]))
            return .located(
                GitRepositoryContext(
                    invocationRoot: topLevel,
                    canonicalCommonGitDirectory: commonDirectory,
                    displayName: topLevel.lastPathComponent
                ))
        case .nonZeroExit:
            return .notRepository
        default:
            return .failure(mapFailure(contextResult))
        }
    }

    private func nearestExistingDirectory(to startingURL: URL) -> URL? {
        let fileManager = FileManager.default
        var candidate = canonicalURL(startingURL.path)
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            candidate.deleteLastPathComponent()
        }

        while !fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory)
            || !isDirectory.boolValue
        {
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else { return nil }
            candidate = parent
        }
        return candidate
    }

    private func canonicalURL(_ path: String) -> URL {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
    }

    private func strictUTF8(_ data: Data) -> String? {
        String(data: data, encoding: .utf8)
    }

    private func mapFailure(_ result: BoundedCommandResult) -> GitRepositoryLocationFailure {
        switch result {
        case .executableNotFound:
            return .executableNotFound
        case .spawnFailure:
            return .spawnFailure
        case .timedOut:
            return .timedOut
        case .outputTruncated:
            return .outputTruncated
        case .outputNotDrained:
            return .outputNotDrained
        case .success, .nonZeroExit:
            return .malformedOutput
        }
    }
}
