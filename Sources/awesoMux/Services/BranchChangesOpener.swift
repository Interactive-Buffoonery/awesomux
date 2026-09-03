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
    /// Present only when this invocation wrote the shared cache slot. A second
    /// pane can legitimately reuse bytes written by a newer invocation; it must
    /// open the file without registering its own stale render as the file source.
    let markdown: String?
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
    case diffInvocationFailed
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

    func completeWrite(at fileURL: URL) {
        cache.completeWrite(at: fileURL)
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
        pane: TerminalPane,
        chrome: BranchChangesRenderer.Chrome,
        claimingSlot: @Sendable (String) -> Bool
    ) async -> Result<OpenedBranchChanges, BranchChangesFailure> {
        // The remote gate is re-asserted here even though the command checks it
        // on the main actor first. A pane's execution plan is the one input
        // that decides whether a local subprocess is meaningful at all, and a
        // gate that lives only at one call site is a gate the next call site
        // forgets.
        guard case .local = pane.executionPlan else {
            return .failure(.remotePane)
        }

        let model = TerminalPathBarModel.make(pane: pane, session: session)
        guard model.repoRootPath != nil else { return .failure(.noRepository) }
        guard let validatedRoot = model.validatedRepoRootPath else {
            return .failure(.unvalidatedRepository)
        }
        let rootURL = URL(fileURLWithPath: validatedRoot, isDirectory: true)
        guard await redirectedGitDirectoryIsBoundToRoot(rootURL) else {
            return .failure(.unvalidatedRepository)
        }

        let baseRef: String
        switch await resolveBaseRef(inDirectory: rootURL) {
        case .success(let resolved): baseRef = resolved
        case .failure(let failure): return .failure(failure)
        }

        let expectedHeadRef = model.gitBranch.map { "refs/heads/\($0)" } ?? "HEAD"
        guard
            let initialRepository = await repositorySnapshot(
                inDirectory: rootURL,
                baseRef: baseRef
            ),
            initialRepository.rootURL == rootURL.standardizedFileURL,
            initialRepository.headRef == expectedHeadRef
        else {
            return .failure(.repositoryChanged)
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
            return .failure(.diffInvocationFailed)
        }

        // One immutable bookend covers all three claims the rendered document
        // makes: which checkout, which HEAD commit, and which base commit. A
        // branch name alone survives resets/rebases and every detached checkout;
        // a ref name alone also survives a concurrent fetch that moves the base.
        guard
            let finalRepository = await repositorySnapshot(
                inDirectory: rootURL,
                baseRef: baseRef
            ),
            finalRepository == initialRepository
        else {
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
            if wasSuperseded, let sharedFileURL = cache.existingFileURL(cacheIdentityKey: slotKey) {
                return .success(
                    OpenedBranchChanges(
                        fileURL: sharedFileURL,
                        identity: identity,
                        markdown: nil
                    )
                )
            }
            return .failure(wasSuperseded ? .superseded : .cacheWriteFailed)
        }
        return .success(
            OpenedBranchChanges(fileURL: fileURL, identity: identity, markdown: markdown)
        )
    }

    private struct RepositorySnapshot: Equatable {
        let rootURL: URL
        let headObjectID: String
        let baseObjectID: String
        let headRef: String
    }

    /// Reads the repository identity and both compared object IDs in one Git
    /// process. The top-level check catches a checkout identity change; the
    /// separate gitdir/worktree binding check above handles redirected `.git`
    /// files because Git itself reports the invoking directory for that shape.
    private func repositorySnapshot(
        inDirectory directory: URL,
        baseRef: String
    ) async -> RepositorySnapshot? {
        let result = await runner.run(
            arguments: [
                "--no-optional-locks",
                "rev-parse",
                "--path-format=absolute",
                "--show-toplevel",
                "HEAD",
                baseRef,
                "--symbolic-full-name",
                "HEAD",
            ],
            inDirectory: directory
        )
        guard case .success(let data) = result,
            let output = String(data: data, encoding: .utf8)
        else { return nil }
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count == 5, lines.last?.isEmpty == true else { return nil }
        let headObjectID = String(lines[1])
        let baseObjectID = String(lines[2])
        guard Self.isObjectID(headObjectID), Self.isObjectID(baseObjectID) else { return nil }
        return RepositorySnapshot(
            rootURL: URL(fileURLWithPath: String(lines[0]), isDirectory: true)
                .resolvingSymlinksInPath()
                .standardizedFileURL,
            headObjectID: headObjectID,
            baseObjectID: baseObjectID,
            headRef: String(lines[3])
        )
    }

    private static func isObjectID(_ value: String) -> Bool {
        (value.count == 40 || value.count == 64) && value.allSatisfy(\.isHexDigit)
    }

    /// A `.git` file normally identifies either a linked worktree (whose
    /// backlink `TerminalPathBarModel` already verifies) or a submodule admin
    /// directory with an explicit `core.worktree`. A pointer to an unrelated
    /// ordinary repository also passes Git's basic shape checks, but Git then
    /// treats the invoking directory as that repository's work tree and a diff
    /// can disclose its index. Require the explicit worktree binding for that
    /// full-admin-directory shape.
    private func redirectedGitDirectoryIsBoundToRoot(_ rootURL: URL) async -> Bool {
        let dotGit = rootURL.appending(path: ".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) else {
            return false
        }
        if isDirectory.boolValue { return true }

        guard let handle = try? FileHandle(forReadingFrom: dotGit) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4097),
            data.count <= 4096,
            let line = String(data: data, encoding: .utf8)?
                .split(separator: "\n", omittingEmptySubsequences: false).first
        else { return false }
        let marker = "gitdir:"
        let declaration = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard declaration.hasPrefix(marker) else { return false }
        let path = declaration.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return false }
        let adminDirectory =
            (path.hasPrefix("/")
            ? URL(fileURLWithPath: path, isDirectory: true)
            : rootURL.appending(path: path, directoryHint: .isDirectory))
            .resolvingSymlinksInPath().standardizedFileURL

        // The existing validator requires a linked-worktree backlink to this
        // exact `.git` file. Do not impose `core.worktree` on that valid shape.
        if FileManager.default.fileExists(
            atPath: adminDirectory.appending(path: "commondir").path
        ) {
            return true
        }

        let result = await runner.run(
            arguments: ["--no-optional-locks", "config", "--path", "--get", "core.worktree"],
            inDirectory: rootURL
        )
        guard case .success(let data) = result,
            let output = String(data: data, encoding: .utf8)
        else { return false }
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count == 2, lines.last?.isEmpty == true, !lines[0].isEmpty else { return false }
        let configured = URL(
            fileURLWithPath: String(lines[0]),
            relativeTo: adminDirectory
        ).resolvingSymlinksInPath().standardizedFileURL
        return configured == rootURL.resolvingSymlinksInPath().standardizedFileURL
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
        // A truncated listing is still usable, symref step included: every row
        // that arrived whole names a ref that exists, and `selectBaseRef`
        // already demands the symref's *target* row be present before trusting
        // it. A retained prefix holding both rows answers the question for
        // itself, so a listing-wide veto would only discard the repository's
        // own answer over refs that were never in doubt.
        var wasTruncated = false
        switch result {
        case .success(let output):
            data = output
        case .outputTruncated(let output):
            data = output
            wasTruncated = true
        case .executableNotFound:
            return .failure(.gitUnavailable)
        case .nonZeroExit, .spawnFailure, .timedOut, .outputNotDrained:
            return .failure(.baseResolutionFailed)
        }

        let rows = Self.parseRefRows(data, dropsLastLine: wasTruncated)
        guard let base = Self.selectBaseRef(rows: rows) else {
            // What a truncated listing did NOT contain is not evidence of
            // absence: the rows past the cap were never read. "This repository
            // has no default branch" asserts something about refs awesoMux
            // never saw, so an unmatched truncated listing is reported as the
            // failed lookup it is.
            return .failure(wasTruncated ? .baseResolutionFailed : .noDefaultBranch)
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
    static func selectBaseRef(rows: [String: String]) -> String? {
        if let target = rows[originHeadRef] {
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
            comparisonNotice: { base, repository in
                String(
                    localized: "Compared with \(base) in \(repository).",
                    comment:
                        "Line under the heading of a rendered branch diff naming the base ref and repository it is compared against; both arguments are Markdown code spans"
                )
            },
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
            },
            newFileLabel: String(
                localized: "new file",
                comment: "Status after a file path heading in a rendered branch diff, for a file the branch created"
            ),
            deletedFileLabel: String(
                localized: "deleted",
                comment: "Status after a file path heading in a rendered branch diff, for a file the branch deleted"
            ),
            renamedFromLabel: { previousPath in
                String(
                    localized: "renamed from \(previousPath)",
                    comment: "Status after a file path heading in a rendered branch diff, naming the path the file had before"
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
        case .diffInvocationFailed:
            return String(
                localized: "Git couldn't produce the diff because the command didn't finish correctly. Try again.",
                comment: "Branch diff failure when the git subprocess could not start or drain its output"
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
