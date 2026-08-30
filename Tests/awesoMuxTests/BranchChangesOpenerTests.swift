import AwesoMuxCore
import AwesoMuxTestSupport
import Foundation
import Testing

@testable import awesoMux

@Suite("Branch changes opener")
struct BranchChangesOpenerTests {

    // MARK: - Fixtures

    /// A repository whose `.git` passes `TerminalPathBarModel`'s admin-directory
    /// validation without a real `git init` — the opener's gate reads the
    /// filesystem, and the unit tests must not depend on a subprocess.
    private final class ValidatedRepository {
        let container: URL
        let root: URL
        var cacheDirectory: URL {
            container.appending(path: "cache", directoryHint: .isDirectory)
        }

        init(head: String = "ref: refs/heads/feature/x\n") throws {
            container = FileManager.default.temporaryDirectory
                .appending(
                    path: "awesomux-branch-changes-\(UUID().uuidString)",
                    directoryHint: .isDirectory
                )
            root = container.appending(path: "awesomux", directoryHint: .isDirectory)
            let git = root.appending(path: ".git", directoryHint: .isDirectory)
            for directory in ["objects", "refs"] {
                try FileManager.default.createDirectory(
                    at: git.appending(path: directory, directoryHint: .isDirectory),
                    withIntermediateDirectories: true
                )
            }
            try Data(head.utf8).write(to: git.appending(path: "HEAD"))
        }

        func remove() {
            try? FileManager.default.removeItem(at: container)
        }
    }

    private func session(workingDirectory: String, executionPlan: PaneExecutionPlan = .local)
        -> TerminalSession
    {
        let pane = TerminalPane(
            title: "zsh",
            workingDirectory: workingDirectory,
            executionPlan: executionPlan
        )
        var session = TerminalSession(
            title: "s",
            workingDirectory: workingDirectory,
            layout: .pane(pane)
        )
        session.activePaneID = pane.id
        return session
    }

    private func opener(_ runner: SpyGitRunner, cacheDirectory: URL) -> BranchChangesOpener {
        BranchChangesOpener(
            runner: runner,
            cache: GeneratedDocumentCache(
                cacheDirectoryURL: cacheDirectory,
                fileNameSuffix: BranchChangesOpener.fileNameSuffix
            )
        )
    }

    private static func refListing(_ rows: [(String, String)]) -> BoundedCommandResult {
        .success(Data(rows.map { "\($0.0)\t\($0.1)" }.joined(separator: "\n").utf8))
    }

    private static let headOnMain = BoundedCommandResult.success(Data("feature/x\n".utf8))

    // MARK: - The subprocess gate

    @Test("a remote pane never spawns a command")
    func remotePaneRunsNothing() async throws {
        let repository = try ValidatedRepository()
        defer { repository.remove() }
        let runner = SpyGitRunner(outcomes: [])
        let target = try #require(RemoteTarget(parsing: "user@host"))
        let result = await opener(runner, cacheDirectory: repository.cacheDirectory).open(
            session: session(
                workingDirectory: repository.root.path,
                executionPlan: .ssh(SSHExecution(target: target))
            ),
            chrome: Self.chrome
        )
        #expect(result == .failure(.remotePane))
        #expect(runner.invocations.isEmpty)
    }

    @Test("a directory outside any repository never spawns a command")
    func nonRepositoryRunsNothing() async throws {
        let temporary = try TemporaryDirectory(prefix: "awesomux-branch-changes")
        defer { withExtendedLifetime(temporary) {} }
        let runner = SpyGitRunner(outcomes: [])
        let result = await opener(runner, cacheDirectory: temporary.url).open(
            session: session(workingDirectory: temporary.url.path),
            chrome: Self.chrome
        )
        #expect(result == .failure(.noRepository))
        #expect(runner.invocations.isEmpty)
    }

    @Test("an unvalidated .git never spawns a command")
    func unvalidatedRepositoryRunsNothing() async throws {
        let temporary = try TemporaryDirectory(prefix: "awesomux-branch-changes")
        defer { withExtendedLifetime(temporary) {} }
        let root = temporary.url.appending(path: "hostile", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // A `.git` with no HEAD, no objects, and no refs: a marker the display
        // path trusts and the subprocess gate does not.
        try FileManager.default.createDirectory(
            at: root.appending(path: ".git", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        let runner = SpyGitRunner(outcomes: [])
        let result = await opener(runner, cacheDirectory: temporary.url).open(
            session: session(workingDirectory: root.path),
            chrome: Self.chrome
        )
        #expect(result == .failure(.unvalidatedRepository))
        #expect(runner.invocations.isEmpty)
    }

    @Test("every invocation runs in the validated repository root")
    func everyInvocationUsesTheValidatedRoot() async throws {
        let repository = try ValidatedRepository()
        defer { repository.remove() }
        let nested = repository.root.appending(path: "deep/nested", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let runner = SpyGitRunner(outcomes: [
            Self.refListing([("refs/remotes/origin/main", "")]),
            .success(Data("+diff\n".utf8)),
            Self.headOnMain,
        ])
        _ = await opener(runner, cacheDirectory: repository.cacheDirectory).open(
            session: session(workingDirectory: nested.path),
            chrome: Self.chrome
        )
        #expect(runner.invocations.count == 3)
        let expected = repository.root.resolvingSymlinksInPath().standardizedFileURL.path
        for invocation in runner.invocations {
            #expect(invocation.directory.standardizedFileURL.path == expected)
        }
    }

    // MARK: - Base resolution ladder

    @Test("origin/HEAD's symref target wins when it names a ref in the same listing")
    func symrefTargetWinsTheLadder() {
        let rows = [
            "refs/remotes/origin/HEAD": "refs/remotes/origin/develop",
            "refs/remotes/origin/develop": "",
            "refs/remotes/origin/main": "",
            "refs/heads/main": "",
        ]
        #expect(
            BranchChangesOpener.selectBaseRef(rows: rows, allowsSymref: true)
                == "refs/remotes/origin/develop"
        )
    }

    @Test("a symref target absent from the listing falls through to the ladder")
    func danglingSymrefFallsThrough() {
        let rows = [
            "refs/remotes/origin/HEAD": "refs/remotes/origin/gone",
            "refs/remotes/origin/master": "",
        ]
        #expect(
            BranchChangesOpener.selectBaseRef(rows: rows, allowsSymref: true)
                == "refs/remotes/origin/master"
        )
    }

    @Test(
        "a symref target outside origin, self-referential, or option-shaped is refused",
        arguments: [
            "refs/heads/main",
            "--output=/tmp/pwned",
            "-x",
            "refs/remotes/origin/HEAD",
        ]
    )
    func hostileSymrefTargetsAreRefused(target: String) {
        let rows = [
            "refs/remotes/origin/HEAD": target,
            "refs/heads/main": "",
            "--output=/tmp/pwned": "",
            "-x": "",
        ]
        #expect(
            BranchChangesOpener.selectBaseRef(rows: rows, allowsSymref: true) == "refs/heads/main"
        )
    }

    @Test("the ladder order is origin/main, origin/master, main, master")
    func ladderOrderIsStable() {
        var rows = ["refs/heads/master": ""]
        #expect(BranchChangesOpener.selectBaseRef(rows: rows, allowsSymref: true) == "refs/heads/master")
        rows["refs/heads/main"] = ""
        #expect(BranchChangesOpener.selectBaseRef(rows: rows, allowsSymref: true) == "refs/heads/main")
        rows["refs/remotes/origin/master"] = ""
        #expect(
            BranchChangesOpener.selectBaseRef(rows: rows, allowsSymref: true)
                == "refs/remotes/origin/master")
        rows["refs/remotes/origin/main"] = ""
        #expect(
            BranchChangesOpener.selectBaseRef(rows: rows, allowsSymref: true)
                == "refs/remotes/origin/main")
    }

    @Test("output line order never decides the base")
    func lineOrderIsIrrelevant() {
        let forwards = BranchChangesOpener.parseRefRows(
            Data(
                """
                refs/remotes/origin/HEAD\trefs/remotes/origin/develop
                refs/remotes/origin/develop\t
                """.utf8
            ),
            dropsLastLine: false
        )
        let backwards = BranchChangesOpener.parseRefRows(
            Data(
                """
                refs/remotes/origin/develop\t
                refs/remotes/origin/HEAD\trefs/remotes/origin/develop
                """.utf8
            ),
            dropsLastLine: false
        )
        #expect(forwards == backwards)
        #expect(
            BranchChangesOpener.selectBaseRef(rows: forwards, allowsSymref: true)
                == "refs/remotes/origin/develop")
    }

    @Test("a truncated listing drops the symref step and its partial last row")
    func truncatedListingFallsBackToTheLadder() {
        let rows = BranchChangesOpener.parseRefRows(
            Data(
                """
                refs/heads/main\t
                refs/remotes/origin/HEAD\trefs/remotes/origin/dev
                refs/remotes/origin/ma
                """.utf8
            ),
            dropsLastLine: true
        )
        #expect(rows["refs/remotes/origin/ma"] == nil)
        #expect(
            BranchChangesOpener.selectBaseRef(rows: rows, allowsSymref: false) == "refs/heads/main")
    }

    @Test("a truncation that landed on a newline keeps its complete last row")
    func truncationOnALineBoundaryKeepsTheFinalRow() {
        // The cap cut between rows, not through one: the last line is whole, and
        // dropping it would hide the only rung this repository offers.
        let rows = BranchChangesOpener.parseRefRows(
            Data("refs/heads/trunk\t\nrefs/remotes/origin/main\t\n".utf8),
            dropsLastLine: true
        )
        #expect(rows["refs/remotes/origin/main"] == "")
        #expect(
            BranchChangesOpener.selectBaseRef(rows: rows, allowsSymref: false)
                == "refs/remotes/origin/main")
    }

    @Test("a repository with no remote and no main or master has no base")
    func noDefaultBranch() async throws {
        let repository = try ValidatedRepository()
        defer { repository.remove() }
        let runner = SpyGitRunner(outcomes: [Self.refListing([("refs/heads/trunk", "")])])
        let result = await opener(runner, cacheDirectory: repository.cacheDirectory).open(
            session: session(workingDirectory: repository.root.path),
            chrome: Self.chrome
        )
        #expect(result == .failure(.noDefaultBranch))
        #expect(runner.invocations.count == 1)
    }

    @Test("a base lookup that could not run is not a missing default branch")
    func baseResolutionFailureIsItsOwnAnswer() async throws {
        let repository = try ValidatedRepository()
        defer { repository.remove() }
        let runner = SpyGitRunner(outcomes: [.timedOut(outputTruncated: false)])
        let result = await opener(runner, cacheDirectory: repository.cacheDirectory).open(
            session: session(workingDirectory: repository.root.path),
            chrome: Self.chrome
        )
        #expect(result == .failure(.baseResolutionFailed))
    }

    @Test("a missing git executable is named as such")
    func missingGitIsNamed() async throws {
        let repository = try ValidatedRepository()
        defer { repository.remove() }
        let runner = SpyGitRunner(outcomes: [.executableNotFound])
        let result = await opener(runner, cacheDirectory: repository.cacheDirectory).open(
            session: session(workingDirectory: repository.root.path),
            chrome: Self.chrome
        )
        #expect(result == .failure(.gitUnavailable))
    }

    // MARK: - Diff outcomes

    @Test("a truncated diff is rendered and marked incomplete")
    func truncationPropagatesToTheDocument() async throws {
        let repository = try ValidatedRepository()
        defer { repository.remove() }
        let runner = SpyGitRunner(outcomes: [
            Self.refListing([("refs/remotes/origin/main", "")]),
            .outputTruncated(Data("+partial\n".utf8)),
            Self.headOnMain,
        ])
        let cacheDirectory = repository.cacheDirectory
        let result = await opener(runner, cacheDirectory: cacheDirectory).open(
            session: session(workingDirectory: repository.root.path),
            chrome: Self.chrome
        )
        let opened = try #require(result.success)
        #expect(opened.markdown.contains("**This diff is incomplete.**"))
        #expect(opened.markdown.hasSuffix("**This diff is incomplete.**\n\n"))
        #expect(try String(contentsOf: opened.fileURL, encoding: .utf8) == opened.markdown)
    }

    @Test("a diff that blew both the size cap and the deadline is refused, not shown")
    func oversizeDiffIsRefused() async throws {
        let repository = try ValidatedRepository()
        defer { repository.remove() }
        let cacheDirectory = repository.cacheDirectory
        let runner = SpyGitRunner(outcomes: [
            Self.refListing([("refs/remotes/origin/main", "")]),
            .timedOut(outputTruncated: true),
        ])
        let result = await opener(runner, cacheDirectory: cacheDirectory).open(
            session: session(workingDirectory: repository.root.path),
            chrome: Self.chrome
        )
        #expect(result == .failure(.diffTooLarge))
        #expect(!FileManager.default.fileExists(atPath: cacheDirectory.path))
    }

    @Test("a timed-out diff writes nothing to the cache")
    func timeoutWritesNothing() async throws {
        let repository = try ValidatedRepository()
        defer { repository.remove() }
        let cacheDirectory = repository.cacheDirectory
        let runner = SpyGitRunner(outcomes: [
            Self.refListing([("refs/remotes/origin/main", "")]),
            .timedOut(outputTruncated: false),
        ])
        let result = await opener(runner, cacheDirectory: cacheDirectory).open(
            session: session(workingDirectory: repository.root.path),
            chrome: Self.chrome
        )
        #expect(result == .failure(.diffTimedOut))
        #expect(!FileManager.default.fileExists(atPath: cacheDirectory.path))
    }

    @Test("a non-zero diff exit carries git's status code")
    func nonZeroExitCarriesTheCode() async throws {
        let repository = try ValidatedRepository()
        defer { repository.remove() }
        let runner = SpyGitRunner(outcomes: [
            Self.refListing([("refs/remotes/origin/main", "")]),
            .nonZeroExit(129),
        ])
        let result = await opener(runner, cacheDirectory: repository.cacheDirectory).open(
            session: session(workingDirectory: repository.root.path),
            chrome: Self.chrome
        )
        #expect(result == .failure(.diffFailed(exitCode: 129)))
    }

    // MARK: - TOCTOU bookend

    @Test("a HEAD that moved during the read discards the diff")
    func headMovementDiscardsTheDiff() async throws {
        let repository = try ValidatedRepository()
        defer { repository.remove() }
        let cacheDirectory = repository.cacheDirectory
        let runner = SpyGitRunner(outcomes: [
            Self.refListing([("refs/remotes/origin/main", "")]),
            .success(Data("+diff\n".utf8)),
            .success(Data("someone-elses-branch\n".utf8)),
        ])
        let result = await opener(runner, cacheDirectory: cacheDirectory).open(
            session: session(workingDirectory: repository.root.path),
            chrome: Self.chrome
        )
        #expect(result == .failure(.repositoryChanged))
        #expect(!FileManager.default.fileExists(atPath: cacheDirectory.path))
    }

    @Test("a bookend that could not run fails closed")
    func unreadableBookendFailsClosed() async throws {
        let repository = try ValidatedRepository()
        defer { repository.remove() }
        let runner = SpyGitRunner(outcomes: [
            Self.refListing([("refs/remotes/origin/main", "")]),
            .success(Data("+diff\n".utf8)),
            .spawnFailure,
        ])
        let result = await opener(runner, cacheDirectory: repository.cacheDirectory).open(
            session: session(workingDirectory: repository.root.path),
            chrome: Self.chrome
        )
        #expect(result == .failure(.repositoryChanged))
    }

    @Test("a detached HEAD bookends against HEAD, not against a branch name")
    func detachedHeadBookend() async throws {
        let repository = try ValidatedRepository(
            head: "3f0c2c9b1d0a7e5b4c3d2e1f00112233445566aa\n"
        )
        let cacheDirectory = repository.cacheDirectory
        let runner = SpyGitRunner(outcomes: [
            Self.refListing([("refs/remotes/origin/main", "")]),
            .success(Data("+diff\n".utf8)),
            .success(Data("HEAD\n".utf8)),
        ])
        let result = await opener(runner, cacheDirectory: cacheDirectory).open(
            session: session(workingDirectory: repository.root.path),
            chrome: Self.chrome
        )
        let opened = try #require(result.success)
        #expect(opened.identity.gitBranch == nil)
        #expect(opened.identity.displayBranch == "HEAD")
    }

    // MARK: - Cache slots

    @Test("re-running against the same branch replaces the same file")
    func rerunReusesTheSameSlot() async throws {
        let repository = try ValidatedRepository()
        defer { repository.remove() }
        let cacheDirectory = repository.cacheDirectory
        func run(_ diff: String) async throws -> OpenedBranchChanges {
            let runner = SpyGitRunner(outcomes: [
                Self.refListing([("refs/remotes/origin/main", "")]),
                .success(Data(diff.utf8)),
                Self.headOnMain,
            ])
            let result = await opener(runner, cacheDirectory: cacheDirectory).open(
                session: session(workingDirectory: repository.root.path),
                chrome: Self.chrome
            )
            return try #require(result.success)
        }
        let first = try await run("+first\n")
        let second = try await run("+second\n")
        #expect(first.fileURL == second.fileURL)
        #expect(try String(contentsOf: second.fileURL, encoding: .utf8).contains("+second"))
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: cacheDirectory.path).count == 1)
    }

    @MainActor
    @Test("a superseded invocation leaves the shared slot to the newer one")
    func supersededInvocationWritesNothing() async throws {
        let repository = try ValidatedRepository()
        defer { repository.remove() }
        let cacheDirectory = repository.cacheDirectory
        // Two different panes, one repository, one branch, one base ref — so one
        // cache slot. Tickets are issued in press order, on the main actor.
        let stale = BranchChangesInvocations.begin(paneID: UUID())
        let current = BranchChangesInvocations.begin(paneID: UUID())

        func run(_ diff: String, ticket: Int) async
            -> Result<OpenedBranchChanges, BranchChangesFailure>
        {
            let runner = SpyGitRunner(outcomes: [
                Self.refListing([("refs/remotes/origin/main", "")]),
                .success(Data(diff.utf8)),
                Self.headOnMain,
            ])
            return await opener(runner, cacheDirectory: cacheDirectory).open(
                session: session(workingDirectory: repository.root.path),
                chrome: Self.chrome,
                claimingSlot: { BranchChangesInvocations.claimSlot($0, ticket: ticket) }
            )
        }

        // The newer invocation finishes FIRST. That is the ordering a per-pane
        // gate cannot survive: it would discard neither result, and the older
        // run's bytes would land on disk under the newer run's open tab.
        let winner = try #require((await run("+current\n", ticket: current)).success)
        let loser = await run("+stale\n", ticket: stale)

        #expect(loser == .failure(.superseded))
        let onDisk = try String(contentsOf: winner.fileURL, encoding: .utf8)
        #expect(onDisk.contains("+current"))
        #expect(!onDisk.contains("+stale"))
        #expect(onDisk == winner.markdown)
        #expect(try FileManager.default.contentsOfDirectory(atPath: cacheDirectory.path).count == 1)
    }

    @MainActor
    @Test("pressing the command again on one pane supersedes the run already in flight")
    func aSecondPressOnTheSamePaneSupersedesTheFirst() {
        let pane = UUID()
        let slot = BranchChangesOpener.cacheIdentityKey(
            validatedRepoRootPath: "/repo-\(UUID().uuidString)",
            gitBranch: "feature/x",
            baseRef: "refs/remotes/origin/main"
        )
        let first = BranchChangesInvocations.begin(paneID: pane)
        let second = BranchChangesInvocations.begin(paneID: pane)
        #expect(!BranchChangesInvocations.isCurrent(first, paneID: pane))
        #expect(BranchChangesInvocations.isCurrent(second, paneID: pane))
        // Same ordering at the slot, whichever finishes first: one counter
        // serves both gates, so they cannot disagree about which run is newer.
        #expect(BranchChangesInvocations.claimSlot(slot, ticket: second))
        #expect(!BranchChangesInvocations.claimSlot(slot, ticket: first))
        #expect(!BranchChangesInvocations.claimSlot(slot, ticket: second))
    }

    @Test("branches sharing a long prefix land in different slots")
    func longSharedPrefixesGetDistinctSlots() {
        let prefix = String(repeating: "release/2026-08-", count: 4)
        let first = BranchChangesOpener.cacheIdentityKey(
            validatedRepoRootPath: "/repo", gitBranch: prefix + "a", baseRef: "refs/heads/main")
        let second = BranchChangesOpener.cacheIdentityKey(
            validatedRepoRootPath: "/repo", gitBranch: prefix + "b", baseRef: "refs/heads/main")
        #expect(first != second)
    }

    @Test("a field boundary cannot be shifted between the root, the branch, and the base")
    func slotKeyIsLengthPrefixed() {
        #expect(
            BranchChangesOpener.cacheIdentityKey(
                validatedRepoRootPath: "/a", gitBranch: "b", baseRef: "c")
                != BranchChangesOpener.cacheIdentityKey(
                    validatedRepoRootPath: "/a", gitBranch: "", baseRef: "bc")
        )
    }

    @Test("a detached HEAD cannot collide with a branch of the same name")
    func detachedSlotMarkerIsNotAValidRefname() {
        // A leading space is illegal in a refname, so nothing git can produce
        // equals the marker.
        #expect(BranchChangesOpener.detachedSlotMarker.hasPrefix(" "))
        #expect(
            BranchChangesOpener.cacheIdentityKey(
                validatedRepoRootPath: "/a", gitBranch: nil, baseRef: "c")
                != BranchChangesOpener.cacheIdentityKey(
                    validatedRepoRootPath: "/a", gitBranch: "HEAD", baseRef: "c")
        )
    }

    // MARK: - Prune keep-set

    @MainActor
    @Test("the keep-set retains a branch diff by identity OR by directory membership")
    func keepSetUnionsIdentityAndDirectoryMembership() throws {
        let temporary = try TemporaryDirectory(prefix: "awesomux-branch-changes")
        defer { withExtendedLifetime(temporary) {} }
        let cacheDirectory = temporary.url.appending(
            path: BranchChangesOpener.cacheDirectoryName,
            directoryHint: .isDirectory
        )
        // In the cache directory but with no identity — the case a tolerant
        // decode produces.
        let byDirectory = cacheDirectory.appending(path: "one.branch-changes.md")
        // Carries an identity but sits somewhere the store no longer recognizes
        // — a moved Application Support, or a cache that failed validation.
        let byIdentity = temporary.url.appending(path: "stranded.branch-changes.md")
        // A user's own file that happens to carry the suffix is not ours.
        let userFile = temporary.url.appending(path: "notes.branch-changes.md")

        let identity = try #require(
            BranchChangesIdentity(
                gitBranch: "feature/x",
                baseRef: "refs/remotes/origin/main",
                repositoryName: "awesomux"
            ))
        let terminal = TerminalPane(title: "shell", workingDirectory: "~", executionPlan: .local)
        let tabs = [
            DocumentPane(fileURL: byDirectory, title: "one"),
            DocumentPane(fileURL: byIdentity, title: "two", branchChangesIdentity: identity),
            DocumentPane(fileURL: userFile, title: "notes"),
        ]
        let workspace = TerminalSession(
            title: "shell",
            workingDirectory: "~",
            layout: .split(
                TerminalSplit(
                    orientation: .vertical,
                    first: .pane(terminal),
                    second: .documentGroup(DocumentGroup(tabs: tabs, selectedTabID: tabs[0].id))
                )
            ),
            activePaneID: terminal.id
        )
        let store = SessionStore(
            restoring: SessionSnapshot(
                groups: [SessionGroup(name: "ops", sessions: [workspace])],
                selectedSessionID: workspace.id
            )
        )

        let references = SessionPersistence.generatedDocumentReferences(
            keeping: store,
            branchChanges: BranchChangesOpener(
                cache: GeneratedDocumentCache(
                    cacheDirectoryURL: cacheDirectory,
                    fileNameSuffix: BranchChangesOpener.fileNameSuffix
                )
            )
        )
        #expect(references.branchChanges == [byDirectory, byIdentity])
        #expect(!references.branchChanges.contains(userFile))
        #expect(references.agentTranscripts.isEmpty)
    }

    // MARK: - Failure copy

    @Test("every failure has its own non-empty sentence")
    func everyFailureHasADistinctSentence() {
        let failures: [BranchChangesFailure] = [
            .remotePane, .noRepository, .unvalidatedRepository, .noDefaultBranch,
            .gitUnavailable, .baseResolutionFailed, .diffFailed(exitCode: 129), .diffTimedOut,
            .diffTooLarge, .repositoryChanged, .cacheWriteFailed, .paneClosed, .superseded,
        ]
        let sentences = failures.map(BranchChangesOpener.failureDescription(for:))
        #expect(sentences.allSatisfy { !$0.isEmpty })
        #expect(Set(sentences).count == failures.count)
        // The exit code has to reach the user; "git failed" alone is a support
        // ticket rather than a report.
        #expect(BranchChangesOpener.failureDescription(for: .diffFailed(exitCode: 129)).contains("129"))
    }

    // MARK: - Integration

    /// The one test that runs REAL git. Everything above stubs the runner, so
    /// nothing above would notice if the production argv were rejected — and
    /// `git diff` exits 129 for the option order this feature very nearly used.
    @Test("the production argv runs against a real repository")
    func productionArgvWorksAgainstRealGit() async throws {
        let fixture = try GitFixture()
        defer { fixture.remove() }
        try fixture.git(["checkout", "-q", "-b", "feature/x"])
        try fixture.commit(file: "a.txt", contents: "changed\n", message: "work")

        let runner = BoundedLocalGitCommandRunner(timeout: .seconds(30))
        let diff = await runner.run(
            arguments: BranchChangesOpener.diffArguments(baseRef: "refs/heads/main"),
            inDirectory: fixture.repository
        )
        let data = try #require(diff.completeData)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("a.txt"))
        #expect(text.contains("+changed"))
    }

    @Test("a real origin/HEAD pointing at develop resolves develop as the base")
    func realOriginHeadResolvesToDevelop() async throws {
        let fixture = try GitFixture()
        defer { fixture.remove() }
        try fixture.git(["checkout", "-q", "-b", "develop"])
        try fixture.commit(file: "b.txt", contents: "b\n", message: "develop work")
        try fixture.git(["checkout", "-q", "main"])

        let clone = fixture.root.appending(path: "clone", directoryHint: .isDirectory)
        try fixture.git(["clone", "-q", fixture.repository.path, clone.path], cwd: fixture.root)
        try fixture.git(
            ["remote", "set-head", "origin", "develop"], cwd: clone)

        let opener = BranchChangesOpener(
            runner: BoundedLocalGitCommandRunner(timeout: .seconds(30)),
            cache: GeneratedDocumentCache(
                cacheDirectoryURL: fixture.root.appending(path: "cache", directoryHint: .isDirectory),
                fileNameSuffix: BranchChangesOpener.fileNameSuffix
            )
        )
        let base = await opener.resolveBaseRef(inDirectory: clone)
        #expect(base == .success("refs/remotes/origin/develop"))
    }

    // MARK: - Shared chrome

    private static let chrome = BranchChangesRenderer.Chrome(
        title: "Branch changes",
        branchLabel: "Branch",
        baseLabel: "Compared with",
        repositoryLabel: "Repository",
        snapshotNotice: "Snapshot taken just now.",
        untrackedNotice: "Untracked files are not included.",
        truncationNotice: "This diff is incomplete.",
        emptyNotice: { "This branch matches \($0)." }
    )
}

// MARK: - Test doubles

private extension Result where Success == OpenedBranchChanges, Failure == BranchChangesFailure {
    var success: OpenedBranchChanges? {
        guard case .success(let value) = self else { return nil }
        return value
    }
}

private extension BranchChangesOpener {
    /// The uncontended case, which is every test that is not about the slot
    /// gate. Test-only: `open` takes the claim with no default precisely so the
    /// app cannot silently skip it.
    func open(
        session: TerminalSession,
        chrome: BranchChangesRenderer.Chrome
    ) async -> Result<OpenedBranchChanges, BranchChangesFailure> {
        await open(session: session, chrome: chrome, claimingSlot: { _ in true })
    }
}

private final class SpyGitRunner: LocalGitCommandRunning, @unchecked Sendable {
    struct Invocation: Sendable {
        let arguments: [String]
        let directory: URL
    }

    private let lock = NSLock()
    private var remaining: [BoundedCommandResult]
    private var recorded: [Invocation] = []

    init(outcomes: [BoundedCommandResult]) {
        remaining = outcomes
    }

    var invocations: [Invocation] {
        lock.withLock { recorded }
    }

    func run(arguments: [String], inDirectory directory: URL) async -> BoundedCommandResult {
        lock.withLock {
            recorded.append(Invocation(arguments: arguments, directory: directory))
            guard !remaining.isEmpty else { return .spawnFailure }
            return remaining.removeFirst()
        }
    }
}

/// A real git repository on disk, for the two integration tests.
private final class GitFixture {
    let root: URL
    let repository: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(
                path: "awesomux-branch-changes-\(UUID().uuidString)", directoryHint: .isDirectory)
        repository = root.appending(path: "primary", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"])
        try commit(file: "a.txt", contents: "original\n", message: "initial")
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func commit(file: String, contents: String, message: String) throws {
        try Data(contents.utf8).write(to: repository.appending(path: file))
        try git(["add", file])
        try git(["commit", "-q", "-m", message])
    }

    func git(_ arguments: [String], cwd: URL? = nil) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments =
            [
                "-c", "user.name=awesoMux Tests",
                "-c", "user.email=tests@awesomux.local",
                "-c", "commit.gpgsign=false",
                "-c", "protocol.file.allow=always",
            ] + arguments
        process.currentDirectoryURL = cwd ?? repository
        process.environment = [
            "PATH": "/usr/bin:/bin",
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_PAGER": "cat",
            "PAGER": "cat",
            "HOME": root.path,
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw GitFixtureError(command: arguments, status: process.terminationStatus)
        }
    }
}

private struct GitFixtureError: Error {
    let command: [String]
    let status: Int32
}
