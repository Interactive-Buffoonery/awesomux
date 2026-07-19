import Foundation

// MARK: - CIStatusInfo

/// The CI state surfaced by the Path Bar's CI chip, derived from the newest
/// GitHub Actions run on the active pane's branch. Only the two states worth
/// interrupting for are representable — `.failing` and `.running`; a passing,
/// cancelled, skipped, or absent run produces no value (and thus no chip), so
/// "silent" is unrepresentable-as-a-chip by construction rather than a state the
/// view has to remember to hide.
///
/// The run it describes is the newest *remote* run for the branch, NOT CI for the
/// local `HEAD`: a user with unpushed commits (the dirty / ahead chips will say
/// so) can see `CI ✕` for an already-superseded commit. That's an accepted MVP
/// trade-off — the alternative (match runs to the local head SHA) shows nothing
/// for any unpushed commit, which is worse for the common case.
struct CIStatusInfo: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case failing
        case running
    }

    let state: State
    let url: URL
    /// GitHub's `databaseId` for the run — the argument to `gh run watch` /
    /// `gh run view`. Named to make the source explicit: a future edit must not
    /// swap in the run *number* (a different, per-workflow value) and silently
    /// break watch/view. An `Int` (64-bit on macOS) holds it; run IDs exceed
    /// `Int32`.
    let runDatabaseID: Int
    /// `owner/repo`, derived and char-validated from the run URL. Pins the
    /// `gh run watch/view` commands with `--repo` so they target the run's repo
    /// rather than whatever directory the pane's shell happens to be in (a run id
    /// is only meaningful within its repo). Nil when it can't be cleanly derived,
    /// in which case the ⌥ action degrades to copying the URL.
    let repoSlug: String?
    /// The workflow's display name (e.g. "Swift CI"), surfaced in the tooltip /
    /// VoiceOver label so `CI ✕` isn't opaque in a repo with several workflows —
    /// and so it reads as "this workflow's latest run," not "PR CI." Nil when gh
    /// omits it.
    let workflowName: String?

    init(state: State, url: URL, runDatabaseID: Int, repoSlug: String?, workflowName: String?) {
        self.state = state
        self.url = url
        self.runDatabaseID = runDatabaseID
        self.repoSlug = repoSlug
        self.workflowName = workflowName
    }

    /// Active `status` values that mean "the run is in flight." Anything outside
    /// this set that isn't `completed` (an unknown / future gh status) maps to nil
    /// rather than being painted as running — a chip that guesses is worse than no
    /// chip. `waiting` (deployment-gate approval) counts as running: the pipeline
    /// is mid-flight from the user's view.
    private static let runningStatuses: Set<String> = [
        "queued", "in_progress", "requested", "waiting", "pending",
    ]

    /// Parses the first element of
    /// `gh run list --json databaseId,status,conclusion,url,workflowName` (always a
    /// JSON array). Returns nil — meaning "no chip" — for an empty array, a
    /// passing/cancelled/skipped/unknown-status run, a non-https url, or malformed
    /// output.
    init?(parsingGhJSON data: Data) {
        struct Payload: Decodable {
            let databaseId: Int
            let status: String
            // Nullable on the wire: an in-progress run reports `conclusion` as ""
            // (and some gh versions emit null). `decodeIfPresent` tolerates "",
            // null, and an absent key alike — and a running run's conclusion is
            // never read anyway, since `status` is checked first.
            let conclusion: String?
            let url: String
            let workflowName: String?
        }

        guard let payloads = try? JSONDecoder().decode([Payload].self, from: data),
            let payload = payloads.first
        else {
            return nil
        }

        let resolvedState: State
        let status = payload.status.lowercased()
        if status == "completed" {
            switch (payload.conclusion ?? "").lowercased() {
            case "failure", "timed_out", "startup_failure":
                resolvedState = .failing
            default:
                // success / cancelled / skipped / neutral / stale → no chip.
                // `action_required` (a run awaiting manual approval) is DELIBERATELY
                // silent too: the chip is a two-state failing/running design (per the
                // issue), and a manual-gate state is neither. Revisit if a distinct
                // "needs attention" state is ever wanted.
                return nil
            }
        } else if Self.runningStatuses.contains(status) {
            resolvedState = .running
        } else {
            // Unknown / unrecognized status — don't paint a guess.
            return nil
        }

        // The url crosses a trust boundary: gh derives it from the repo's git
        // remote, which a cloned/agent-checked-out repo's owner may not control.
        // Refuse anything but https so a hostile remote can't make a single click
        // open `file://`, a custom scheme, or `javascript:`.
        guard let url = URL(string: payload.url),
            url.scheme?.lowercased() == "https"
        else {
            return nil
        }

        self.state = resolvedState
        self.url = url
        self.runDatabaseID = payload.databaseId
        self.repoSlug = Self.repoSlug(from: url, runDatabaseID: payload.databaseId)
        self.workflowName = Self.sanitizedDisplay(payload.workflowName)
    }

    /// Derives `owner/repo` from a run URL for `gh run --repo` pinning, but ONLY
    /// when the URL is an exact github.com run URL:
    /// `https://github.com/<owner>/<repo>/actions/runs/<databaseID>`. This is
    /// deliberately strict — a bare `firstTwoPathComponents` would mis-derive
    /// `repos/owner` from an `api.github.com/repos/...` URL, and silently drop the
    /// host of a `github.example.com` (Enterprise) URL so `--repo owner/repo` would
    /// target the wrong server. Off-shape, non-github.com, or id-mismatched URLs
    /// yield nil, and the ⌥ action degrades to copy. Segments are also char-checked
    /// since the slug is interpolated into a command typed into the user's pane.
    private static func repoSlug(from url: URL, runDatabaseID: Int) -> String? {
        guard url.host?.lowercased() == "github.com" else {
            return nil
        }
        let segments = url.pathComponents.filter { $0 != "/" }
        guard segments.count == 5,
            segments[2] == "actions",
            segments[3] == "runs",
            segments[4] == String(runDatabaseID)
        else {
            return nil
        }
        let owner = segments[0]
        let repo = segments[1]
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-"
        )
        guard !owner.isEmpty, !repo.isEmpty,
            owner.unicodeScalars.allSatisfy(allowed.contains),
            repo.unicodeScalars.allSatisfy(allowed.contains)
        else {
            return nil
        }
        return "\(owner)/\(repo)"
    }

    /// Strips C0/DEL control bytes and bidi override/embedding/isolate format
    /// characters from gh-supplied display text (the workflow name), then caps its
    /// length. The name comes from a workflow file in a repo the user may not
    /// control and is rendered into the tooltip and VoiceOver label, so a U+202E
    /// override could otherwise spoof it — same treatment the branch label gets.
    private static func sanitizedDisplay(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let speechSafe = TerminalAccessibilityPathFormatter.sanitizedForSpeech(raw)
        let filtered = speechSafe.unicodeScalars.filter { scalar in
            switch scalar.value {
            case 0x202A...0x202E,  // LRE RLE PDF LRO RLO
                0x2066...0x2069:  // LRI RLI FSI PDI
                false
            default:
                true
            }
        }
        let result = String(String.UnicodeScalarView(filtered))
            .trimmingCharacters(in: .whitespaces)
        guard !result.isEmpty else {
            return nil
        }
        return String(result.prefix(120))
    }
}

// MARK: - Command runner

/// Production runner: spawns `gh run list` via the shared `BoundedCommandRunner`.
/// Injected into `CIStatusResolver` as a `StatusCommandRunner` closure.
struct GhCIStatusCommandRunner: Sendable {
    private static let command = BoundedCommandRunner(executableCandidates: [
        "/opt/homebrew/bin/gh",
        "/usr/local/bin/gh",
        "/usr/bin/gh",
    ])

    func run(repoRoot: String, branch: String) async -> Data? {
        // `branch` is the *value* of `--branch` (not a positional), so gh's flag
        // parser consumes it as the value even if it begins with `-` — no `--`
        // terminator needed here (unlike `gh pr view <branch>`). It still rides in
        // its own argv slot, never a shell string, so a hostile branch name from
        // another repo's HEAD can't inject.
        // Fail-closed: truncated JSON must not paint a partial CI status.
        await Self.command.runDetailed(
            arguments: [
                "run", "list",
                "--branch", branch,
                "--limit", "1",
                "--json", "databaseId,status,conclusion,url,workflowName",
            ],
            inDirectory: repoRoot
        ).completeData
    }
}

// MARK: - Resolver

/// Caches CI lookups (via the shared `CachedAsyncResolver`) so the Path Bar's
/// frequent re-resolution spawns `gh` at most once per branch per TTL window. The
/// TTL is shortest for `.running` (it's actively changing) and short for
/// `.failing` too (that's the state the user is trying to leave — a stale ✕ after
/// they've pushed a fix is the most annoying), longer for "no chip".
struct CIStatusResolver: Sendable {
    static let shared = CIStatusResolver(runner: GhCIStatusCommandRunner().run)

    private struct Key: Hashable, Sendable {
        let repoRoot: String
        let branch: String
    }

    private let resolver: CachedAsyncResolver<Key, CIStatusInfo?>

    init(
        runner: @escaping StatusCommandRunner,
        runningTTL: TimeInterval = 15,
        failingTTL: TimeInterval = 20,
        absentTTL: TimeInterval = 30,
        cacheCap: Int = 64,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        resolver = CachedAsyncResolver(
            cacheCap: cacheCap,
            now: now,
            ttl: { info in
                switch info?.state {
                case .running: runningTTL
                case .failing: failingTTL
                case nil: absentTTL
                }
            },
            fetch: { key in
                await runner(key.repoRoot, key.branch)
                    .flatMap(CIStatusInfo.init(parsingGhJSON:))
            }
        )
    }

    func status(repoRoot: String, branch: String) async -> CIStatusInfo? {
        await resolver.value(for: Key(repoRoot: repoRoot, branch: branch))
    }
}
