import Foundation

struct GitRepositoryContext: Equatable, Sendable {
    var invocationRoot: URL
    var canonicalCommonGitDirectory: URL
    var displayName: String
}

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

    init(
        executableCandidates: [String] = ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"],
        timeout: Duration = .seconds(5),
        maxOutputBytes: Int = 512 * 1024
    ) {
        runner = BoundedCommandRunner(
            executableCandidates: executableCandidates,
            timeout: timeout,
            maxOutputBytes: maxOutputBytes
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
