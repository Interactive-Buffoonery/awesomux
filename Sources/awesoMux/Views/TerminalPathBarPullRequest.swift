import Foundation

// MARK: - PullRequestInfo

/// The open GitHub pull request associated with the active pane's branch, as
/// surfaced by the Path Bar's PR chip. Only OPEN PRs are represented — a closed
/// or merged PR produces no chip.
struct PullRequestInfo: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case open
        case draft
        case inReview
    }

    let number: Int
    let url: URL
    let state: State

    init(number: Int, url: URL, state: State) {
        self.number = number
        self.url = url
        self.state = state
    }

    /// Parses one object from
    /// `gh pr view <branch> --json number,url,state,isDraft,reviewDecision`.
    /// Returns nil unless the payload is a single OPEN PR with an https URL.
    init?(parsingGhJSON data: Data) {
        struct Payload: Decodable {
            let number: Int
            let url: String
            let state: String
            let isDraft: Bool
            let reviewDecision: String?
        }

        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return nil
        }

        // The chip is open-PRs-only; gh happily returns CLOSED/MERGED for a branch
        // whose last PR is gone.
        guard payload.state.uppercased() == "OPEN" else {
            return nil
        }

        // The URL crosses a trust boundary: it is derived from the repo's git
        // remote, which the user may not control (a cloned/agent-checked-out
        // repo). Refuse anything but https so a hostile remote can't make a
        // single click open `file://`, a custom scheme, or `javascript:`.
        guard let url = URL(string: payload.url),
            url.scheme?.lowercased() == "https"
        else {
            return nil
        }

        self.number = payload.number
        self.url = url
        if payload.isDraft {
            self.state = .draft
        } else if let decision = payload.reviewDecision?.uppercased(),
            decision == "REVIEW_REQUIRED" || decision == "CHANGES_REQUESTED"
        {
            self.state = .inReview
        } else {
            // APPROVED or no review required ("") both read as a plain open PR.
            self.state = .open
        }
    }
}

// MARK: - Command runner

/// Production runner: spawns `gh pr view` via the shared `BoundedCommandRunner`.
/// Injected into `PullRequestResolver` as a `StatusCommandRunner` closure.
struct GhPullRequestCommandRunner: Sendable {
    private static let command = BoundedCommandRunner(executableCandidates: [
        "/opt/homebrew/bin/gh",
        "/usr/local/bin/gh",
        "/usr/bin/gh",
    ])

    func run(repoRoot: String, branch: String) async -> Data? {
        // Arguments array (never a shell string) so a hostile branch name can't
        // shell-inject — `branch` originates from another repo's .git/HEAD. The
        // `--` terminator is also load-bearing: a valid branch like `--web` or
        // `--json=x` (refs/heads/--web is legal) would otherwise be parsed by gh
        // as a flag, not the positional branch.
        // Fail-closed: truncated JSON is not parseable as an authoritative PR.
        await Self.command.runDetailed(
            arguments: [
                "pr", "view",
                "--json", "number,url,state,isDraft,reviewDecision",
                "--", branch,
            ],
            inDirectory: repoRoot
        ).completeData
    }
}

// MARK: - Resolver

/// Caches PR lookups (via the shared `CachedAsyncResolver`) so the Path Bar's
/// frequent re-resolution spawns `gh` at most once per branch per TTL window.
/// A found PR is cached longer than a miss, so a just-created PR (`gh pr create`)
/// shows within the shorter negative window rather than the full positive one.
struct PullRequestResolver: Sendable {
    static let shared = PullRequestResolver(runner: GhPullRequestCommandRunner().run)

    private struct Key: Hashable, Sendable {
        let repoRoot: String
        let branch: String
    }

    private let resolver: CachedAsyncResolver<Key, PullRequestInfo?>

    init(
        runner: @escaping StatusCommandRunner,
        positiveTTL: TimeInterval = 90,
        negativeTTL: TimeInterval = 20,
        cacheCap: Int = 64,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        resolver = CachedAsyncResolver(
            cacheCap: cacheCap,
            now: now,
            ttl: { $0 == nil ? negativeTTL : positiveTTL },
            fetch: { key in
                await runner(key.repoRoot, key.branch)
                    .flatMap(PullRequestInfo.init(parsingGhJSON:))
            }
        )
    }

    func pullRequest(repoRoot: String, branch: String) async -> PullRequestInfo? {
        await resolver.value(for: Key(repoRoot: repoRoot, branch: branch))
    }
}
