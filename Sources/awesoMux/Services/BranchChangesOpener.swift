import AwesoMuxCore
import Foundation

// MARK: - Result types

/// A rendered branch diff ready to open in a document tab.
struct OpenedBranchChanges: Equatable, Sendable {
    /// The cache file to hand `openDocumentPane`. Regenerable storage — the
    /// identity, not this, is the tab's provenance.
    let fileURL: URL
    let identity: BranchChangesIdentity
    /// The exact source written to `fileURL`, so the caller can register the
    /// write with the self-write registry before the file watcher sees it. A
    /// refresh must not surface as somebody else's edit.
    let markdown: String
}

/// Everything that can stop a branch diff reaching the screen.
///
/// One case per thing the user could do about it. "Couldn't show the changes"
/// for all of them is a support ticket: several are fixable right now, and each
/// names a different fix.
enum BranchChangesFailure: Error, Equatable, Sendable {
    case remotePane
    case noRepository
    case unvalidatedRepository
    case noDefaultBranch
    case gitUnavailable
    case baseResolutionFailed
    case diffFailed(exitCode: Int32)
    case diffTimedOut
    case diffTooLarge
    case repositoryChanged
    case cacheWriteFailed
    /// A newer invocation already claimed this render's cache slot, so it wrote
    /// nothing. Never surfaced: the newer run is the one the user is waiting on,
    /// and an alert here would report the command they pressed twice as broken.
    case superseded
    /// The pane went away while the diff ran. Raised by the command, not the
    /// opener — it is the only failure that is about awesoMux's own state
    /// rather than the repository's.
    case paneClosed
}

// MARK: - Latest-wins gate

/// Latest-wins for overlapping Show Branch Changes invocations.
///
/// Not an in-flight lock, deliberately. Blocking a second invocation would make
/// the command feel dead exactly when the user pressed it again *because* the
/// repository moved and they want the newer answer. Instead both run and only
/// the newest one is allowed to land — git finishes in whatever order it likes,
/// and without this the slower run's older diff lands last and wins.
///
/// **Two things need ordering, not one.** The pane's own reaction — the tab it
/// opens, the alert it raises — is per pane. The rendered file is not: the cache
/// slot is keyed by repository root, branch, and base ref, so two panes on the
/// same branch of the same checkout render into ONE file, and a superseded run
/// finishing late overwrites it under an already-open tab. Because that write is
/// not registered with the self-write registry, the tab's watcher reloads stale
/// bytes and reports them as somebody else's edit.
///
/// **One counter serves both**, and that is the point rather than a saving. The
/// ticket is issued on the main actor when the command is pressed, so pane order
/// and slot order are the same order by construction: the run whose UI reaction
/// is discarded can never be the run whose bytes are on disk. A counter started
/// later — once the slot key is finally known, after base resolution — would
/// order by whichever run resolved its base first, which is not the order the
/// pane gate uses, and the two gates disagreeing is the same bug wearing a
/// different hat.
///
/// None of the three maps (pane tickets, slot tickets, registered tickets) is
/// pruned: an entry is a few words, a pane, slot, or path that will never be
/// seen again also never costs anything again, and the registration high-water
/// mark MUST survive to reject arbitrarily late completions. `ponytail:
/// unbounded maps; prune on pane close if a session ever churns panes in the
/// millions.`
@MainActor
enum BranchChangesInvocations {
    private static var nextTicket = 0
    private static var paneTickets: [TerminalPane.ID: Int] = [:]

    /// Issues the ticket for one invocation and makes it the pane's current one.
    static func begin(paneID: TerminalPane.ID) -> Int {
        nextTicket += 1
        paneTickets[paneID] = nextTicket
        return nextTicket
    }

    static func isCurrent(_ ticket: Int, paneID: TerminalPane.ID) -> Bool {
        paneTickets[paneID] == ticket
    }

    private static var registeredTickets: [URL: Int] = [:]

    /// Whether `ticket` may register bytes for `fileURL` with the self-write
    /// registry, recording it as the path's newest registrant if so.
    ///
    /// Completions arrive on the main actor in any order. Without this gate, a
    /// stale successful completion landing AFTER the current one would
    /// re-register the path with older bytes, and the watcher would then read
    /// the newer on-disk content as somebody else's edit — the mirror image of
    /// the unregistered-write bug this gate's caller exists to prevent. The
    /// slot claim guarantees disk holds the highest-claiming ticket's bytes,
    /// so accepting only monotonically increasing tickets per path converges
    /// the registry on what is actually on disk.
    ///
    /// ponytail: a stale completion arriving BEFORE the current one still
    /// registers its (already overwritten) bytes for a moment; the registry's
    /// short validity window and byte comparison bound the exposure to one
    /// transient indicator. Registering inside the write's critical section
    /// would close it, at the cost of a main-actor hop under the cache lock.
    static func shouldRegister(_ ticket: Int, for fileURL: URL) -> Bool {
        guard (registeredTickets[fileURL] ?? 0) < ticket else { return false }
        registeredTickets[fileURL] = ticket
        return true
    }

    // MARK: Cache slots

    // `nonisolated(unsafe)` promise: accessed only under `slotLock`. Not on the
    // main actor because the claim is taken by the render, which runs detached.
    nonisolated private static let slotLock = NSLock()
    nonisolated(unsafe) private static var slotTickets: [String: Int] = [:]

    /// Claims `slot` for `ticket`, or refuses because a newer invocation already
    /// holds it.
    ///
    /// Claim and write have to be one step — a caller that asked "am I still
    /// current?" and then wrote would leave exactly the window this closes — so
    /// this is called from inside `GeneratedDocumentCache.write`'s critical
    /// section, and a refusal means the bytes are never written at all.
    nonisolated static func claimSlot(_ slot: String, ticket: Int) -> Bool {
        slotLock.withLock {
            guard (slotTickets[slot] ?? 0) < ticket else { return false }
            slotTickets[slot] = ticket
            return true
        }
    }
}

// MARK: - Opener

/// Resolves a base ref, runs one bounded `git diff`, renders it, and stores the
/// result in awesoMux's owner-only cache.
///
/// Deliberately not `@MainActor`: it spawns subprocesses and renders up to a
/// couple of MiB, so callers run this off the main actor and only touch the
/// store with the result.
///
/// **The subprocess gate is the whole security posture.** Not one command runs
/// unless `TerminalPathBarModel.validatedRepoRootPath` is non-nil, and every
/// invocation's working directory IS that validated root — never the pane's
/// working directory, never `repoRootPath` (which is set for any `.git` marker,
/// including an attacker-shaped one). `TerminalPathBarView` records why that
/// distinction exists.
struct BranchChangesOpener: Sendable {
    static let cacheDirectoryName = "branch-changes"

    /// Deliberately not a bare `.md` — see `GeneratedDocumentCache.fileNameSuffix`.
    static let fileNameSuffix = ".branch-changes.md"

    /// Ten seconds and 1 MiB. The Path Bar's five-second / 512 KB defaults are
    /// sized for a `git status` summary; a real diff exceeds both as a matter
    /// of course, so this needs its own bounds — and a diff that blows past
    /// them is reported as too large rather than shown half-finished.
    static let diffTimeout: Duration = .seconds(10)
    static let diffMaximumOutputBytes = 1024 * 1024

    /// The base refs tried in order, as full refnames. Full rather than short,
    /// so git can never resolve one as a path, and so the ladder cannot be
    /// shadowed by a local branch that happens to be named `origin/main`.
    static let baseRefLadder = [
        "refs/remotes/origin/main",
        "refs/remotes/origin/master",
        "refs/heads/main",
        "refs/heads/master",
    ]

    /// The ref namespaces `for-each-ref` is asked for. The `origin` namespace
    /// pattern is REQUIRED rather than an exact `refs/remotes/origin/HEAD`
    /// pattern: the symref target has to be present in the same result set for
    /// the ladder to confirm it exists, and an exact pattern's output cannot
    /// contain the row that would confirm it.
    static let refPatterns = [
        "refs/remotes/origin",
        "refs/heads/main",
        "refs/heads/master",
    ]

    static let originHeadRef = "refs/remotes/origin/HEAD"
    static let originPrefix = "refs/remotes/origin/"

    /// The cache-slot stand-in for a detached HEAD. A leading space is illegal
    /// in a refname, so no real branch can collide with it.
    static let detachedSlotMarker = " detached HEAD"

    private let runner: any LocalGitCommandRunning
    private let cache: GeneratedDocumentCache

    init(
        runner: any LocalGitCommandRunning = BoundedLocalGitCommandRunner(
            timeout: BranchChangesOpener.diffTimeout,
            maxOutputBytes: BranchChangesOpener.diffMaximumOutputBytes
        ),
        cache: GeneratedDocumentCache = GeneratedDocumentCache(
            cacheDirectoryURL: GeneratedDocumentCache.supportDirectoryURL(
                named: BranchChangesOpener.cacheDirectoryName
            ),
            fileNameSuffix: BranchChangesOpener.fileNameSuffix
        )
    ) {
        self.runner = runner
        self.cache = cache
    }

    /// Whether `url` is a slot in the branch-changes cache.
    func contains(_ url: URL) -> Bool { cache.contains(url) }

    func schedulePruneUnreferenced(keeping referencedFileURLs: Set<URL>) {
        cache.schedulePruneUnreferenced(keeping: referencedFileURLs)
    }

    func pruneUnreferencedImmediately(keeping referencedFileURLs: Set<URL>) {
        cache.pruneUnreferencedImmediately(keeping: referencedFileURLs)
    }

    // MARK: Open

    /// - Parameter claimingSlot: Called with the cache slot key at the moment of
    ///   the write, inside the cache's write lock, and answering whether this
    ///   invocation is still the one entitled to that slot. `false` aborts the
    ///   write — the second half of the same bookend the HEAD re-read is the
    ///   first half of, and for the same reason: everything checked before a
    ///   ten-second subprocess is a fact about the past by the time the bytes
    ///   land. No default value on purpose; a gate that a call site can forget
    ///   to pass is a gate that is dead in production and green in tests.
    func open(
        session: TerminalSession,
        chrome: BranchChangesRenderer.Chrome,
        claimingSlot: @Sendable (String) -> Bool
    ) async -> Result<OpenedBranchChanges, BranchChangesFailure> {
        // The remote gate is re-asserted here even though the command checks it
        // on the main actor first. A pane's execution plan is the one input
        // that decides whether a local subprocess is meaningful at all, and a
        // gate that lives only at one call site is a gate the next call site
        // forgets.
        guard case .local = session.activePane?.executionPlan ?? .local else {
            return .failure(.remotePane)
        }

        let model = TerminalPathBarModel.make(session: session)
        guard model.repoRootPath != nil else { return .failure(.noRepository) }
        guard let validatedRoot = model.validatedRepoRootPath else {
            return .failure(.unvalidatedRepository)
        }
        let rootURL = URL(fileURLWithPath: validatedRoot, isDirectory: true)

        let baseRef: String
        switch await resolveBaseRef(inDirectory: rootURL) {
        case .success(let resolved): baseRef = resolved
        case .failure(let failure): return .failure(failure)
        }

        guard
            let identity = BranchChangesIdentity(
                gitBranch: model.gitBranch,
                baseRef: baseRef,
                repositoryName: rootURL.lastPathComponent
            )
        else {
            // Every component came from a validated repository root and a ref
            // this process just read, so reaching here means the repository's
            // own names are unrenderable. There is no honest tab to open.
            return .failure(.noRepository)
        }

        let diff: Data
        var isTruncated = false
        switch await runner.run(
            arguments: Self.diffArguments(baseRef: baseRef),
            inDirectory: rootURL
        ) {
        case .success(let data):
            diff = data
        case .outputTruncated(let data):
            diff = data
            isTruncated = true
        case .timedOut(outputTruncated: true):
            // The cap was already breached when the deadline fired. That is a
            // fact about the output the kill cannot retract, and for a caller
            // whose cap IS a size limit it is the answer — not a hang.
            return .failure(.diffTooLarge)
        case .timedOut:
            return .failure(.diffTimedOut)
        case .nonZeroExit(let code):
            return .failure(.diffFailed(exitCode: code))
        case .executableNotFound:
            return .failure(.gitUnavailable)
        case .spawnFailure, .outputNotDrained:
            return .failure(.diffTimedOut)
        }

        // TOCTOU bookend. HEAD was read from `.git/HEAD` before the diff ran;
        // a checkout or a finished rebase in between would have produced a diff
        // for a branch the tab is about to name something else.
        //
        // ponytail: names only. A detached HEAD that moved between two commits
        // still reports `HEAD` both times and slips through. Compare object ids
        // if that case ever matters — it costs a second bounded `rev-parse`.
        switch await runner.run(
            arguments: ["--no-optional-locks", "rev-parse", "--abbrev-ref", "HEAD"],
            inDirectory: rootURL
        ) {
        case .success(let data):
            let head = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard head == (model.gitBranch ?? "HEAD") else {
                return .failure(.repositoryChanged)
            }
        default:
            // The bookend cannot confirm HEAD held still, so the diff cannot be
            // presented as this branch's. Fail closed.
            return .failure(.repositoryChanged)
        }

        let markdown = BranchChangesRenderer.render(
            diff: diff,
            identity: identity,
            isTruncated: isTruncated,
            chrome: chrome
        )
        let slotKey = Self.cacheIdentityKey(
            validatedRepoRootPath: validatedRoot,
            gitBranch: model.gitBranch,
            baseRef: baseRef
        )
        var wasSuperseded = false
        let written = cache.write(markdown, cacheIdentityKey: slotKey) {
            let claimed = claimingSlot(slotKey)
            wasSuperseded = !claimed
            return claimed
        }
        guard let fileURL = written else {
            return .failure(wasSuperseded ? .superseded : .cacheWriteFailed)
        }
        return .success(
            OpenedBranchChanges(fileURL: fileURL, identity: identity, markdown: markdown)
        )
    }

    // MARK: Base resolution

    /// One bounded `for-each-ref` listing, then a client-side ladder.
    ///
    /// Client-side rather than `git symbolic-ref refs/remotes/origin/HEAD`
    /// followed by fallbacks, because that is four more subprocesses on the
    /// common path and this needs one. Output line ORDER is never relied on —
    /// `for-each-ref` sorts by refname, so `origin/HEAD` arrives before
    /// `origin/main` today and nothing in the format promises it will tomorrow.
    func resolveBaseRef(inDirectory directory: URL) async -> Result<String, BranchChangesFailure> {
        let result = await runner.run(
            arguments: ["--no-optional-locks", "for-each-ref", "--format=%(refname)%09%(symref)"]
                + Self.refPatterns,
            inDirectory: directory
        )
        let data: Data
        // A truncated listing is still usable for the non-symref ladder: those
        // entries are exact refnames, and a row that parsed is a row that
        // exists. Only the symref step is dropped, because the row confirming
        // its target may be the one that got cut.
        var allowsSymref = true
        switch result {
        case .success(let output):
            data = output
        case .outputTruncated(let output):
            data = output
            allowsSymref = false
        case .executableNotFound:
            return .failure(.gitUnavailable)
        case .nonZeroExit, .spawnFailure, .timedOut, .outputNotDrained:
            return .failure(.baseResolutionFailed)
        }

        let rows = Self.parseRefRows(data, dropsLastLine: !allowsSymref)
        guard
            let base = Self.selectBaseRef(rows: rows, allowsSymref: allowsSymref)
        else {
            return .failure(.noDefaultBranch)
        }
        return .success(base)
    }

    /// `refname` → symref target (empty when the ref is not symbolic).
    ///
    /// - Parameter dropsLastLine: Whether the final line may be a fragment
    ///   because the output hit its cap. Only *may*: a cap that landed exactly
    ///   on a newline cut between rows rather than through one, so the final
    ///   line is whole and dropping it would discard a rung the ladder could
    ///   have used. The trailing newline is the evidence, and it is the one the
    ///   common case has — `for-each-ref` terminates every row.
    static func parseRefRows(_ data: Data, dropsLastLine: Bool) -> [String: String] {
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        if dropsLastLine, !text.hasSuffix("\n"), !lines.isEmpty {
            lines.removeLast()
        }
        var rows: [String: String] = [:]
        for line in lines {
            let fields = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard let name = fields.first, !name.isEmpty else { continue }
            rows[String(name)] = fields.count > 1 ? String(fields[1]) : ""
        }
        return rows
    }

    /// The first ladder rung that names a ref actually present in `rows`.
    static func selectBaseRef(rows: [String: String], allowsSymref: Bool) -> String? {
        if allowsSymref, let target = rows[originHeadRef] {
            // Accepted only if it points inside `origin`, is not `origin/HEAD`
            // itself, and names a ref this same listing saw. The prefix check
            // is what stops a hostile checkout's `refs/remotes/origin/HEAD`
            // from handing git an argument of its choosing; the leading-dash
            // guard is the second fence for the same attack.
            if target.hasPrefix(originPrefix), target != originHeadRef,
                !target.hasPrefix("-"), rows[target] != nil
            {
                return target
            }
        }
        return baseRefLadder.first { rows[$0] != nil }
    }

    // MARK: Commands

    /// Diff options come AFTER the subcommand. Git exits 129 ("usage") when a
    /// diff-only option is passed before `diff`, so the order here is load
    /// bearing rather than stylistic.
    ///
    /// `--merge-base` compares the merge base of `baseRef` and HEAD with the
    /// *working tree*, so uncommitted work on the branch is included and
    /// untracked files are not — which is what the document's header says.
    /// `-c diff.external=` and `--no-ext-diff` / `--no-textconv` keep a repo's
    /// configured helpers from being spawned once per changed file inside a
    /// ten-second budget. `core.fsmonitor=false` keeps a configured watchman
    /// from being started by this read.
    static func diffArguments(baseRef: String) -> [String] {
        [
            "--no-optional-locks",
            "-c", "core.fsmonitor=false",
            "-c", "diff.external=",
            "diff",
            "--no-ext-diff",
            "--no-textconv",
            "--no-color",
            "--merge-base",
            baseRef,
            "--",
        ]
    }

    // MARK: Cache slot

    /// The slot key: the validated root, the raw branch, and the base ref,
    /// length-prefixed so the boundary between fields cannot be shifted.
    ///
    /// Stable across renders on purpose. `PaneLayoutReducer.openDocumentTab`
    /// dedupes by normalized URL and `DocumentFileWatcher` re-arms across the
    /// atomic rename, so running the command again refreshes the open tab in
    /// place instead of stacking a second one beside it.
    static func cacheIdentityKey(
        validatedRepoRootPath: String,
        gitBranch: String?,
        baseRef: String
    ) -> String {
        GeneratedDocumentCache.cacheIdentityKey(
            domain: "branch-changes",
            fields: [validatedRepoRootPath, gitBranch ?? detachedSlotMarker, baseRef]
        )
    }

    // MARK: Localized document chrome

    /// The app layer owns localization (ADR-0014), so the words awesoMux writes
    /// into the document are composed here and passed down. Same split as
    /// `AgentTranscriptOpener.localizedChrome`, for the same reasons.
    static func localizedChrome(snapshotTakenAt: Date = Date()) -> BranchChangesRenderer.Chrome {
        let time = snapshotTakenAt.formatted(date: .omitted, time: .shortened)
        return BranchChangesRenderer.Chrome(
            title: String(
                localized: "Branch changes",
                comment: "Heading of a rendered branch diff document"
            ),
            branchLabel: String(
                localized: "Branch",
                comment: "Label before the branch name in a rendered branch diff"
            ),
            baseLabel: String(
                localized: "Compared with",
                comment: "Label before the base ref in a rendered branch diff"
            ),
            repositoryLabel: String(
                localized: "Repository",
                comment: "Label before the repository name in a rendered branch diff"
            ),
            snapshotNotice: String(
                localized:
                    "Snapshot taken at \(time). Run Show Branch Changes again to refresh it.",
                comment:
                    "Notice in a rendered branch diff naming when it was taken and how to refresh it"
            ),
            untrackedNotice: String(
                localized:
                    "Committed and uncommitted work on this branch is included. Untracked files are not.",
                comment:
                    "Notice in a rendered branch diff explaining which changes the comparison covers"
            ),
            truncationNotice: String(
                localized: "This diff is incomplete.",
                comment: "Notice shown above and below a branch diff that was cut short"
            ),
            emptyNotice: { base in
                String(
                    localized: "This branch matches \(base). There is nothing to show.",
                    comment:
                        "Notice in a rendered branch diff when the branch and its base are identical"
                )
            }
        )
    }

    // MARK: Failure copy

    /// A distinct sentence per failure. One sentence covering all of them is a
    /// support ticket: several are things the user can fix right now, and each
    /// names a different fix.
    static func failureDescription(for failure: BranchChangesFailure) -> String {
        switch failure {
        case .remotePane:
            return String(
                localized:
                    "This pane runs over SSH, and its repository is on the remote host. Show the changes from a local pane.",
                comment: "Branch diff failure when the pane runs over SSH"
            )
        case .noRepository:
            return String(
                localized:
                    "This pane's working directory isn't inside a git repository, so there is no branch to compare.",
                comment: "Branch diff failure when the pane's directory is not in a repository"
            )
        case .unvalidatedRepository:
            return String(
                localized:
                    "awesoMux found a .git here but wouldn't run git against it — it may be a symlink, or point somewhere outside the repository.",
                comment:
                    "Branch diff failure when the repository's .git failed admin-directory validation"
            )
        case .noDefaultBranch:
            return String(
                localized:
                    "awesoMux couldn't find a branch to compare against. It looks for origin's default branch, then main or master — a repository with no remote, no commits, or differently named branches has none of them.",
                comment:
                    "Branch diff failure when no default base branch could be resolved, including the no-remote and empty-repository cases"
            )
        case .gitUnavailable:
            return String(
                localized:
                    "awesoMux couldn't find git. Install the Xcode command line tools, or git through Homebrew, and try again.",
                comment: "Branch diff failure when no git executable was found"
            )
        case .baseResolutionFailed:
            return String(
                localized:
                    "awesoMux couldn't read this repository's branches. Git didn't finish the lookup.",
                comment:
                    "Branch diff failure when the ref listing could not be run or did not complete"
            )
        case .diffFailed(let exitCode):
            return String(
                localized: "Git couldn't produce the diff. It exited with status \(exitCode).",
                comment: "Branch diff failure naming the exit status git returned"
            )
        case .diffTimedOut:
            return String(
                localized:
                    "Git took too long to produce the diff and awesoMux stopped waiting. Try again, or run git diff in the terminal.",
                comment: "Branch diff failure when the git subprocess hit its deadline"
            )
        case .diffTooLarge:
            return String(
                localized:
                    "This branch's diff is larger than awesoMux can render. Compare a narrower range in the terminal instead.",
                comment: "Branch diff failure when the diff exceeded both the size cap and the deadline"
            )
        case .repositoryChanged:
            return String(
                localized:
                    "The repository changed while awesoMux was reading it, so the diff wouldn't have matched the branch it names. Try again.",
                comment: "Branch diff failure when HEAD moved between the start and end of the read"
            )
        case .cacheWriteFailed:
            return String(
                localized: "awesoMux couldn't save the rendered diff to its cache.",
                comment: "Branch diff failure when writing the rendered Markdown to the app cache fails"
            )
        case .paneClosed:
            return String(
                localized: "The pane closed while awesoMux was preparing the changes.",
                comment: "Branch diff failure when the originating pane went away mid-render"
            )
        case .superseded:
            // Present so the enum stays exhaustively described, not because a
            // user sees it: the caller returns silently on this case, because a
            // newer run of the same command is still on its way to the screen.
            return String(
                localized: "A newer run of Show Branch Changes replaced this one.",
                comment: "Branch diff outcome when a newer invocation superseded this one"
            )
        }
    }
}
