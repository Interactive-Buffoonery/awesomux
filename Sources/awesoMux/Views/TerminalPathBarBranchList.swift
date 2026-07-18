import Foundation

// MARK: - Command runner

/// Production runner: `git for-each-ref` via the shared `BoundedCommandRunner`.
/// Injected into `BranchListResolver` as a closure so tests never shell out.
struct BranchListCommandRunner: Sendable {
    private static let command = BoundedCommandRunner(executableCandidates: [
        "/opt/homebrew/bin/git",
        "/usr/local/bin/git",
        "/usr/bin/git",
    ])

    func run(repoRoot: String) async -> Data? {
        // `--no-optional-locks` / fsmonitor-off for the same reasons as the
        // status runner: a background read must never contend with the user's
        // foreground git, and a hostile repo-local fsmonitor program must not
        // execute (see GitStatusCommandRunner).
        // Prefix-safe: `BranchListMenuModel.parse` drops a mid-line fragment
        // when the trailing newline is missing after a capped read.
        await Self.command.run(
            arguments: [
                "--no-optional-locks",
                "-c", "core.fsmonitor=false",
                "for-each-ref", "refs/heads",
                "--sort=-committerdate",
                "--format=%(refname:short)",
            ],
            inDirectory: repoRoot
        ).dataAllowingTruncation
    }
}

// MARK: - Menu model

/// Pure helpers behind the branch foldout: parsing the for-each-ref output,
/// separating the pinned current branch from the clickable rows, and building
/// the inserted checkout command.
enum BranchListMenuModel {
    static func parse(_ data: Data) -> [String] {
        let text = String(decoding: data, as: UTF8.self)
        var lines =
            text
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map(String.init)
            .filter { !$0.isEmpty }
        // `for-each-ref` output always ends with a trailing newline when
        // complete; `BoundedCommandRunner` caps stdout at 512 KB and can slice
        // mid-line, so a missing trailing newline reliably means the last
        // line is a truncated fragment — drop it rather than render a
        // garbled (and possibly wrong) clickable row.
        if !text.isEmpty, !text.hasSuffix("\n"), !text.hasSuffix("\r"), !lines.isEmpty {
            lines.removeLast()
        }
        return lines
    }

    static func otherBranches(branches: [String], currentBranch: String?) -> [String] {
        // Leading-dash refs are droppable, not quotable: plumbing can create
        // `refs/heads/-f`, quoting doesn't stop git's own argv parsing, and an
        // inserted `git checkout '-f'` would force-checkout (discarding local
        // changes) instead of erroring. Such a branch can't be checked out by
        // short name anyway, so a row for it could only ever misfire.
        //
        // A name carrying control bytes or a bidi override/embedding/isolate
        // scalar (Trojan-Source spoofing) is EXCLUDED rather than display-
        // sanitized: this row's checkout command executes the raw
        // `for-each-ref` bytes, so a row that can't be safely acted on
        // shouldn't be a row at all.
        let checkoutSafe = branches.filter {
            !$0.hasPrefix("-") && !BranchNameSanitizer.containsSpoofableScalars($0)
        }
        guard let currentBranch else { return checkoutSafe }
        return checkoutSafe.filter { $0 != currentBranch }
    }

    /// Cap on clickable rows in the foldout. `for-each-ref` is recency-sorted
    /// (`--sort=-committerdate`), so the first 12 are the branches the user
    /// actually switches between; deeper needs mean typing the checkout
    /// yourself (or a future filter field). The cap replaces the old
    /// `ScrollView`-past-8 path, which never worked: a ScrollView inside the
    /// menu's `.fixedSize(horizontal: true, vertical: false)` container
    /// collapses its content to zero height (pinned row + phantom gap only).
    static let maxVisibleRows = 12

    static func visibleRows(_ branches: [String]) -> (visible: [String], overflow: Int) {
        (Array(branches.prefix(maxVisibleRows)), max(0, branches.count - maxVisibleRows))
    }

    static func checkoutCommand(branch: String) -> String {
        // Git refnames exclude most shell metacharacters, but not `'` on every
        // platform — quote defensively since this string is typed into a live
        // shell prompt. No `--` separator on purpose: `git checkout -- <arg>`
        // would flip the command into pathspec mode, checking out FILES named
        // like the branch instead of switching to it. Option-shaped
        // (leading `-`) names are filtered out in `otherBranches` instead.
        let escaped = branch.replacingOccurrences(of: "'", with: "'\\''")
        return "git checkout '\(escaped)'"
    }
}

// MARK: - Resolver

/// Caches branch-list lookups (via the shared `CachedAsyncResolver`) on a short
/// TTL: the list only changes on branch create/delete/commit, but the menu can
/// be reopened rapidly and must not respawn git each time. Keyed by repo root.
struct BranchListResolver: Sendable {
    static let shared = BranchListResolver(runner: { repoRoot in
        await BranchListCommandRunner().run(repoRoot: repoRoot)
    })

    private let resolver: CachedAsyncResolver<String, [String]?>

    init(
        runner: @escaping @Sendable (_ repoRoot: String) async -> Data?,
        ttl: TimeInterval = 8,
        cacheCap: Int = 64,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        resolver = CachedAsyncResolver(
            cacheCap: cacheCap,
            now: now,
            ttl: { _ in ttl },
            fetch: { repoRoot in
                guard let data = await runner(repoRoot) else { return nil }
                return BranchListMenuModel.parse(data)
            }
        )
    }

    func branches(repoRoot: String) async -> [String]? {
        await resolver.value(for: repoRoot)
    }
}
