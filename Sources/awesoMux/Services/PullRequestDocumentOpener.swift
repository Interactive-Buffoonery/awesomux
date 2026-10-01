import AwesoMuxCore
import Foundation
import UnicodeHygiene

struct OpenedPullRequestDocument: Equatable, Sendable {
    let fileURL: URL
    let markdown: String
    let title: String
    let leaseID: UUID
}

enum PullRequestDocumentFailure: Error, Equatable, Sendable {
    case remotePane, invalidRepository, detachedHead, noGitHubRepository, noPullRequest
    case commandFailed, tooLarge, cacheWriteFailed, ambiguousPullRequest, sourceChanged, unsupportedResponse

    var description: String {
        switch self {
        case .remotePane:
            String(
                localized: "Pull request documents require a local pane.",
                comment: "Reason a connected pull request document could not open")
        case .invalidRepository:
            String(
                localized: "No validated local repository is available in this pane.",
                comment: "Reason a connected pull request document could not open")
        case .detachedHead:
            String(
                localized: "Check out a branch to open its pull request.",
                comment: "Reason a connected pull request document could not open")
        case .noGitHubRepository:
            String(
                localized:
                    "Pull request documents require a GitHub.com origin remote. Check the origin remote and GitHub CLI authentication.",
                comment: "Reason a connected pull request document could not open")
        case .noPullRequest:
            String(
                localized: "This branch has no open pull request in the connected GitHub repository.",
                comment: "Reason a connected pull request document could not open")
        case .ambiguousPullRequest:
            String(
                localized: "More than one open pull request matches this branch. Open the intended pull request on GitHub.",
                comment: "Reason a connected pull request document could not open")
        case .sourceChanged:
            String(
                localized: "The repository changed before the pull request could open.",
                comment: "Reason a connected pull request document could not open")
        case .unsupportedResponse:
            String(
                localized: "GitHub CLI returned an unsupported response. Update GitHub CLI and try again.",
                comment: "Reason a connected pull request document could not open")
        case .commandFailed:
            String(
                localized:
                    "Could not read the pull request. Check GitHub CLI installation and version, authentication, and network access.",
                comment: "Reason a connected pull request document could not open")
        case .tooLarge:
            String(
                localized: "The pull request document exceeds the supported size limit.",
                comment: "Reason a connected pull request document could not open")
        case .cacheWriteFailed:
            String(
                localized: "Could not save the pull request document.", comment: "Reason a connected pull request document could not open")
        }
    }
}

/// User-requested snapshots only. Reopening replaces the same protected cache slot.
struct PullRequestDocumentOpener: Sendable {
    private struct Repository: Decodable { let nameWithOwner: String; let url: String }
    private struct Author: Decodable { let login: String? }
    private struct HeadRepository: Decodable { let name: String? }
    private struct Check: Decodable {
        let name: String?
        let context: String?
        let status: String?
        let conclusion: String?
        let state: String?
    }
    private struct PullRequest: Decodable {
        let number: Int
        let url: String
        let title: String
        let state: String
        let isDraft: Bool
        let body: String?
        let headRefName: String
        let headRepository: HeadRepository?
        let headRepositoryOwner: Author?
        let statusCheckRollup: [Check]?
    }
    private struct Comment: Decodable {
        let body: String?
        let user: Author?
        let path: String?
        let line: Int?
        let state: String?
    }

    static let cache = GeneratedDocumentCache(
        cacheDirectoryURL: GeneratedDocumentCache.supportDirectoryURL(named: "pull-requests"),
        fileNameSuffix: ".pull-request.md"
    )
    static func scrubbedEnvironment(_ inherited: [String: String]) -> [String: String] {
        var environment = BoundedLocalGitCommandRunner.scrubbing(inherited)
        environment.removeValue(forKey: "GH_REPO")
        environment.removeValue(forKey: "GH_HOST")
        environment.removeValue(forKey: "GH_FORCE_TTY")
        environment.removeValue(forKey: "CLICOLOR_FORCE")
        environment["NO_COLOR"] = "1"
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["GH_NO_UPDATE_NOTIFIER"] = "1"
        return environment
    }
    private static let gh = BoundedCommandRunner(
        executableCandidates: ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"],
        timeout: .seconds(15), maxOutputBytes: 1024 * 1024,
        environment: scrubbedEnvironment(ProcessInfo.processInfo.environment)
    )
    private let ghRunner: BoundedCommandRunner
    private let gitRunner: any LocalGitCommandRunning
    let cache: GeneratedDocumentCache

    init(
        ghRunner: BoundedCommandRunner = Self.gh,
        gitRunner: any LocalGitCommandRunning = BoundedLocalGitCommandRunner(),
        cache: GeneratedDocumentCache = Self.cache
    ) {
        self.ghRunner = ghRunner
        self.gitRunner = gitRunner
        self.cache = cache
    }

    // Subprocess decoding, rendering, and owner-only cache IO stay off the UI actor.
    func open(
        session: TerminalSession, pane: TerminalPane,
        ifStillCurrent: @MainActor @Sendable () -> Bool = { true }
    ) async -> Result<OpenedPullRequestDocument, PullRequestDocumentFailure> {
        guard pane.executionPlan == .local, pane.remotePresentationHost == nil else { return .failure(.remotePane) }
        let model = TerminalPathBarModel.make(pane: pane, session: session)
        guard !Task.isCancelled else { return .failure(.commandFailed) }
        guard let root = model.validatedRepoRootPath else { return .failure(.invalidRepository) }
        guard let branch = model.gitBranch, !branch.isEmpty else { return .failure(.detachedHead) }
        let origin = await gitRunner.run(arguments: ["config", "--get", "remote.origin.url"], inDirectory: URL(fileURLWithPath: root))
        guard !Task.isCancelled else { return .failure(.commandFailed) }
        guard let originData = origin.completeData,
            let originText = String(data: originData, encoding: .utf8),
            let headRepository = Self.gitHubRepository(originText.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return .failure(.noGitHubRepository) }

        do {
            let repository: Repository = try await query(["repo", "view", "--json", "nameWithOwner,url"], root: root)
            guard Self.gitHubRepository(repository.url) == repository.nameWithOwner.lowercased() else {
                return .failure(.noGitHubRepository)
            }
            // --head is a flag value, never gh's number/URL/branch positional selector.
            let candidates: [PullRequest] = try await query(
                [
                    "pr", "list", "--repo", "github.com/\(repository.nameWithOwner)",
                    "--head", branch, "--state", "open", "--limit", "100",
                    "--json", "number,url,title,state,isDraft,body,headRefName,headRepository,headRepositoryOwner,statusCheckRollup",
                ], root: root)
            guard candidates.count < 100 else { return .failure(.tooLarge) }
            let matching = candidates.filter {
                $0.headRefName == branch
                    && "\($0.headRepositoryOwner?.login ?? "")/\($0.headRepository?.name ?? "")".lowercased() == headRepository
            }
            guard matching.count <= 1 else { return .failure(.ambiguousPullRequest) }
            guard let pr = matching.first else { return .failure(.noPullRequest) }
            guard pr.number > 0,
                pr.url.lowercased() == "https://github.com/\(repository.nameWithOwner.lowercased())/pull/\(pr.number)",
                pr.state == "OPEN"
            else { return .failure(.commandFailed) }

            let title = String(
                localized: "Pull Request #\(String(pr.number))",
                comment: "Document tab and heading title; argument is the unformatted GitHub pull request number")
            var markdown = "# \(title)\n\n"
            markdown += Self.quote(
                pr.title + "\n" + pr.url + "\n" + pr.state
                    + (pr.isDraft
                        ? " · " + String(localized: "Draft", comment: "GitHub pull request draft state in a read-only snapshot") : ""))
            markdown +=
                "## \(String(localized: "Description", comment: "Section heading in a read-only pull request snapshot"))\n\n"
                + Self.quote(pr.body ?? "")
            markdown += "## \(String(localized: "Checks", comment: "Section heading in a read-only pull request snapshot"))\n\n"
            markdown += Self.quote(
                String(
                    localized: "Checks reflect GitHub's reported rollup at the time this snapshot was opened.",
                    comment: "Explains freshness of GitHub checks in a manually opened snapshot"))
            for check in pr.statusCheckRollup ?? [] {
                let conclusion = check.conclusion.flatMap { $0.isEmpty ? nil : $0 }
                markdown += Self.quote(
                    (check.name ?? check.context ?? "") + "\n"
                        + (conclusion ?? check.status ?? check.state
                            ?? String(localized: "Unknown", comment: "Fallback status when GitHub reports no check status"))
                )
            }
            for (endpoint, heading) in [
                (
                    "issues/\(pr.number)/comments",
                    String(localized: "Discussion", comment: "Section heading in a read-only pull request snapshot")
                ),
                (
                    "pulls/\(pr.number)/reviews",
                    String(localized: "Reviews", comment: "Section heading in a read-only pull request snapshot")
                ),
                (
                    "pulls/\(pr.number)/comments",
                    String(localized: "Inline Review Comments", comment: "Section heading in a read-only pull request snapshot")
                ),
            ] {
                let pages: [[Comment]] = try await query(
                    [
                        "api", "repos/\(repository.nameWithOwner)/\(endpoint)",
                        "--hostname", "github.com", "--paginate", "--slurp",
                    ], root: root)
                markdown += "## \(heading)\n\n"
                for comment in pages.flatMap({ $0 }) {
                    let attribution = [comment.user?.login, comment.state, comment.path, comment.line.map(String.init)]
                        .compactMap { $0 }.joined(separator: " · ")
                    markdown += Self.quote(attribution + "\n" + (comment.body ?? ""))
                }
                guard markdown.utf8.count <= DocumentURLValidator.maxFileSizeBytes else { return .failure(.tooLarge) }
            }
            let liveOrigin = await gitRunner.run(
                arguments: ["config", "--get", "remote.origin.url"], inDirectory: URL(fileURLWithPath: root))
            guard !Task.isCancelled else { return .failure(.commandFailed) }
            let cacheIdentity = GeneratedDocumentCache.cacheIdentityKey(
                domain: "pull-request", fields: [repository.url.lowercased(), String(pr.number)])
            let renderedMarkdown = markdown
            guard
                await MainActor.run(body: {
                    guard !Task.isCancelled, ifStillCurrent() else { return false }
                    DocumentPaneView.selfWriteRegistry.record(
                        fileURL: cache.fileURL(cacheIdentityKey: cacheIdentity), source: renderedMarkdown, matchingOnly: true)
                    return true
                })
            else { return .failure(.sourceChanged) }
            let liveModel = TerminalPathBarModel.make(pane: pane, session: session)
            guard liveModel.validatedRepoRootPath == root, liveModel.gitBranch == branch,
                let liveOriginData = liveOrigin.completeData,
                let liveOriginText = String(data: liveOriginData, encoding: .utf8),
                Self.gitHubRepository(liveOriginText.trimmingCharacters(in: .whitespacesAndNewlines)) == headRepository
            else { return .failure(.sourceChanged) }
            let leaseID = UUID()
            guard
                let fileURL = cache.write(
                    markdown,
                    cacheIdentityKey: cacheIdentity,
                    leaseID: leaseID,
                    ifStillCurrent: { !Task.isCancelled })
            else {
                return .failure(.cacheWriteFailed)
            }
            return .success(
                OpenedPullRequestDocument(fileURL: fileURL, markdown: markdown, title: title, leaseID: leaseID)
            )
        } catch is DecodingError {
            return .failure(.unsupportedResponse)
        } catch let failure as PullRequestDocumentFailure {
            return .failure(failure)
        } catch {
            return .failure(.commandFailed)
        }
    }

    private func query<T: Decodable>(_ arguments: [String], root: String) async throws -> T {
        try Task.checkCancellation()
        let result = await ghRunner.runDetailed(arguments: arguments, inDirectory: root)
        try Task.checkCancellation()
        switch result {
        case .outputTruncated, .timedOut(outputTruncated: true): throw PullRequestDocumentFailure.tooLarge
        default: break
        }
        guard let data = result.completeData else { throw PullRequestDocumentFailure.commandFailed }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func gitHubRepository(_ value: String) -> String? {
        let path: String
        if value.hasPrefix("git@github.com:") {
            path = String(value.dropFirst("git@github.com:".count))
        } else if let url = URL(string: value), url.host?.lowercased() == "github.com",
            ["https", "ssh"].contains(url.scheme?.lowercased() ?? ""), url.query == nil, url.fragment == nil
        {
            path = String(url.path.dropFirst())
        } else {
            return nil
        }
        let normalized = path.hasSuffix(".git") ? String(path.dropLast(4)) : path
        let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2,
            components.allSatisfy({
                !$0.isEmpty && $0 != "." && $0 != ".."
                    && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
            })
        else { return nil }
        return normalized.lowercased()
    }

    /// Every line remains inside a quoted code block, including empty lines.
    private static func quote(_ raw: String) -> String {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let safe = String(
            String.UnicodeScalarView(
                normalized.unicodeScalars.filter {
                    $0 == "\n" || $0 == "\t" || (!CharacterSet.controlCharacters.contains($0) && !UnicodeHygiene.isDisallowedScalar($0))
                }))
        return safe.components(separatedBy: "\n").map { ">     " + $0 }.joined(separator: "\n") + "\n\n"
    }
}
