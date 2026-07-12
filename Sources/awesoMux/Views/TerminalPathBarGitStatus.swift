import Foundation

// MARK: - GitStatusInfo

/// Working-copy state for the Path Bar's `+N` dirty chip and `↑N ↓N` ahead/behind
/// hint. All counts self-suppress at zero, so a clean, in-sync repo renders nothing.
struct GitStatusInfo: Equatable, Sendable {
    /// Count of changed entries (staged, unstaged, unmerged, and untracked) — i.e.
    /// everything that makes the working copy not clean. A rename is one entry.
    let dirtyCount: Int
    /// Commits the local branch is ahead of / behind its upstream. Both zero when
    /// there is no upstream (detached HEAD, no tracking branch).
    let ahead: Int
    let behind: Int
    /// The branch git actually reported (`# branch.head`), used to detect a TOCTOU
    /// where HEAD changed between `.git/HEAD` being read and `git status` running.
    /// `nil`/`"(detached)"` for detached HEAD.
    let branchHead: String?

    var isClean: Bool { dirtyCount == 0 && ahead == 0 && behind == 0 }

    init(dirtyCount: Int, ahead: Int, behind: Int, branchHead: String? = nil) {
        self.dirtyCount = dirtyCount
        self.ahead = ahead
        self.behind = behind
        self.branchHead = branchHead
    }

    /// Parses `git --no-optional-locks status --porcelain=v2 --branch` output.
    /// Header lines start with `#` (the `# branch.ab +A -B` header carries
    /// ahead/behind); every other non-empty line is one changed/untracked entry.
    init(parsingPorcelainV2 data: Data) {
        var dirty = 0
        var ahead = 0
        var behind = 0
        var head: String?

        for rawLine in String(decoding: data, as: UTF8.self)
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            if rawLine.hasPrefix("#") {
                let aheadBehindPrefix = "# branch.ab "
                let headPrefix = "# branch.head "
                if rawLine.hasPrefix(aheadBehindPrefix) {
                    for field in rawLine.dropFirst(aheadBehindPrefix.count).split(separator: " ") {
                        if field.hasPrefix("+") {
                            ahead = Int(field.dropFirst()) ?? 0
                        } else if field.hasPrefix("-") {
                            behind = Int(field.dropFirst()) ?? 0
                        }
                    }
                } else if rawLine.hasPrefix(headPrefix) {
                    head = String(rawLine.dropFirst(headPrefix.count))
                }
            } else if !rawLine.isEmpty {
                // porcelain v2 entry: `1`/`2` (changed/renamed), `u` (unmerged),
                // `?` (untracked). One line per entry (a rename is a single line
                // with both paths), so a plain line count is the dirty count.
                dirty += 1
            }
        }

        dirtyCount = dirty
        self.ahead = ahead
        self.behind = behind
        branchHead = head
    }
}

// MARK: - Command runner

/// Production runner: `git status` via the shared `BoundedCommandRunner`.
/// Injected into `GitStatusResolver` as a `StatusCommandRunner` closure.
struct GitStatusCommandRunner: Sendable {
    private static let command = BoundedCommandRunner(executableCandidates: [
        "/opt/homebrew/bin/git",
        "/usr/local/bin/git",
        "/usr/bin/git",
    ])

    func run(repoRoot: String) async -> Data? {
        // Flags, in order:
        // - `--no-optional-locks`: a background status read must never take the
        //   index lock or rewrite `.git/index`, or it contends with the user's own
        //   foreground git (commit/rebase) in the pane.
        // - `-c core.fsmonitor=false`: git executes the `core.fsmonitor` program
        //   during `status`. We auto-run status on whatever directory the pane is
        //   in, so a hostile repo-local `.git/config` would otherwise be an RCE
        //   vector — disable it.
        // - `--ahead-behind` / `--untracked-files=normal`: pin the output against
        //   user config that could otherwise suppress ahead/behind or untracked
        //   entries, so the chip counts are deterministic.
        await Self.command.run(
            arguments: [
                "--no-optional-locks",
                "-c", "core.fsmonitor=false",
                "status", "--porcelain=v2", "--branch",
                "--ahead-behind", "--untracked-files=normal",
            ],
            inDirectory: repoRoot
        )
    }
}

// MARK: - Resolver

/// Caches git-status lookups (via the shared `CachedAsyncResolver`) on a short,
/// flat TTL — dirty state changes often, so freshness matters more than a long
/// cache, but the TTL still keeps the frequent title-driven re-resolution from
/// spawning `git status` on every prompt. Keyed by (repoRoot, branch) so an
/// in-place branch switch refreshes the ahead/behind numbers.
struct GitStatusResolver: Sendable {
    static let shared = GitStatusResolver(runner: { repoRoot, _ in
        await GitStatusCommandRunner().run(repoRoot: repoRoot)
    })

    private struct Key: Hashable, Sendable {
        let repoRoot: String
        let branch: String
    }

    private let resolver: CachedAsyncResolver<Key, GitStatusInfo?>

    init(
        runner: @escaping StatusCommandRunner,
        ttl: TimeInterval = 8,
        cacheCap: Int = 64,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        resolver = CachedAsyncResolver(
            cacheCap: cacheCap,
            now: now,
            ttl: { _ in ttl },
            fetch: { key in
                guard let data = await runner(key.repoRoot, key.branch) else {
                    return nil
                }
                let info = GitStatusInfo(parsingPorcelainV2: data)
                // TOCTOU guard: git reads its own current HEAD, which may have
                // changed since `make()` read `.git/HEAD` and keyed this lookup. If
                // the branch git reported differs from the expected branch, the
                // ahead/behind numbers belong to a different branch — drop them so
                // they aren't cached/painted under the wrong chip. The dirty count
                // is working-tree-wide, so it stays valid.
                if !key.branch.isEmpty,
                   let head = info.branchHead,
                   head != key.branch {
                    return GitStatusInfo(dirtyCount: info.dirtyCount, ahead: 0, behind: 0)
                }
                return info
            }
        )
    }

    func status(repoRoot: String, branch: String) async -> GitStatusInfo? {
        await resolver.value(for: Key(repoRoot: repoRoot, branch: branch))
    }
}
