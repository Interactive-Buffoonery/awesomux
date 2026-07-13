import AwesoMuxCore
import Foundation
import Testing

@testable import awesoMux

@Suite("Terminal Path Bar model")
struct TerminalPathBarModelTests {
    private final class ProbeCountingFileManager: FileManager {
        var probeCount = 0

        override func fileExists(atPath path: String) -> Bool {
            probeCount += 1
            return false
        }

        override func fileExists(
            atPath path: String,
            isDirectory: UnsafeMutablePointer<ObjCBool>?
        ) -> Bool {
            probeCount += 1
            return false
        }
    }

    @Test("repo root displays project and repo root label")
    func repoRootDisplaysProjectAndRootLabel() throws {
        let fixture = try PathBarFixture()
        defer { fixture.cleanup() }
        let repo = try fixture.makeRepo(named: "awesomux")
        let session = TerminalSession(
            title: "main",
            workingDirectory: repo.path,
            agentKind: .codex
        )

        let model = TerminalPathBarModel.make(
            session: session,
            homeDirectory: fixture.home
        )

        #expect(model.project == "awesomux")
        #expect(model.path == "repo root")
        #expect(model.branch == "main")
        #expect(model.copyPath == repo.resolvedPath)
    }

    @Test("the model reflects the ACTIVE pane's remote host (split tracking)")
    func remoteHostTracksActivePane() {
        let localPane = TerminalPane(
            title: "ed@mymac: ~/x", workingDirectory: "/tmp", executionPlan: .local)
        let remotePane = TerminalPane(
            title: "ed@webserver: ~/app",
            workingDirectory: "/tmp",
            remoteHost: "webserver",
            remoteConnectionHealth: .possiblyStale, executionPlan: .local)
        let layout = TerminalPaneLayout.split(
            TerminalSplit(
                orientation: .vertical,
                first: .pane(localPane),
                second: .pane(remotePane)
            )
        )

        let remoteActive = TerminalSession(
            title: "w",
            workingDirectory: "/tmp",
            agentKind: .shell,
            layout: layout,
            activePaneID: remotePane.id
        )
        let remoteModel = TerminalPathBarModel.make(session: remoteActive)
        #expect(remoteModel.remoteHost == "webserver")
        #expect(remoteModel.remoteConnectionHealth == .possiblyStale)

        let localActive = TerminalSession(
            title: "w",
            workingDirectory: "/tmp",
            agentKind: .shell,
            layout: layout,
            activePaneID: localPane.id
        )
        #expect(TerminalPathBarModel.make(session: localActive).remoteHost == nil)
    }

    @Test("declared SSH panes never probe the local filesystem")
    func declaredSSHSkipsLocalFilesystem() {
        let target = RemoteTarget(user: "alice", host: "buildbox")
        let pane = TerminalPane(
            title: "remote",
            workingDirectory: "/srv/app",
            executionPlan: .ssh(SSHExecution(target: target))
        )
        let session = TerminalSession(
            title: "remote",
            workingDirectory: "/srv/app",
            layout: .pane(pane),
            activePaneID: pane.id
        )
        let fileManager = ProbeCountingFileManager()

        let model = TerminalPathBarModel.make(session: session, fileManager: fileManager)

        #expect(fileManager.probeCount == 0)
        #expect(model.remoteHost == "alice@buildbox")
        #expect(model.revealURL == nil)
        #expect(model.executionPlan == pane.executionPlan)
    }

    @Test("stale remote copy uses the network-changed warning")
    func staleRemoteCopy() {
        let copy = TerminalPathBarView.remoteIndicatorCopySnapshot(
            host: "webserver",
            health: .possiblyStale
        )

        #expect(copy.icon == "exclamationmark.triangle")
        #expect(copy.accessibilityLabel == "Possibly stale remote session on webserver")
        #expect(
            copy.help
                == "Network changed; this SSH session may be disconnected until SSH recovers or reports failure."
        )
        #expect(copy.accessibilityHint == copy.help)
    }

    @Test("repo subdirectory displays path relative to repo root")
    func repoSubdirectoryDisplaysRelativePath() throws {
        let fixture = try PathBarFixture()
        defer { fixture.cleanup() }
        let repo = try fixture.makeRepo(named: "awesomux")
        let sourceDirectory = repo.appending(path: "Sources/awesoMux/Views")
        try FileManager.default.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: true
        )
        let session = TerminalSession(
            title: "main",
            workingDirectory: sourceDirectory.path,
            agentKind: .codex
        )

        let model = TerminalPathBarModel.make(
            session: session,
            homeDirectory: fixture.home
        )

        #expect(model.project == "awesomux")
        #expect(model.path == "Sources/awesoMux/Views")
        #expect(model.branch == "main")
    }

    @Test("non-repo path collapses home directory")
    func nonRepoPathCollapsesHomeDirectory() throws {
        let fixture = try PathBarFixture()
        defer { fixture.cleanup() }
        let downloads = fixture.home.appending(path: "Downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let session = TerminalSession(
            title: "scratch",
            workingDirectory: downloads.path,
            agentKind: .shell
        )

        let model = TerminalPathBarModel.make(
            session: session,
            homeDirectory: fixture.home
        )

        #expect(model.project == "Downloads")
        #expect(model.path == "~/Downloads")
        #expect(model.branch == nil)
    }

    @Test("active split pane drives the displayed path")
    func activeSplitPaneDrivesDisplayedPath() throws {
        let fixture = try PathBarFixture()
        defer { fixture.cleanup() }
        let repo = try fixture.makeRepo(named: "awesomux")
        let firstDirectory = repo.appending(path: "Sources")
        let secondDirectory = repo.appending(path: "Tests")
        try FileManager.default.createDirectory(
            at: firstDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: secondDirectory, withIntermediateDirectories: true)
        let firstPane = TerminalPane(
            title: "src", workingDirectory: firstDirectory.path, executionPlan: .local)
        let secondPane = TerminalPane(
            title: "tests", workingDirectory: secondDirectory.path, executionPlan: .local)
        let session = TerminalSession(
            title: "workspace",
            workingDirectory: firstDirectory.path,
            agentKind: .codex,
            layout: .split(
                TerminalSplit(
                    orientation: .vertical,
                    first: .pane(firstPane),
                    second: .pane(secondPane)
                )
            ),
            activePaneID: secondPane.id
        )

        let model = TerminalPathBarModel.make(
            session: session,
            homeDirectory: fixture.home
        )

        #expect(model.activePaneTitle == "tests")
        #expect(model.path == "Tests")
        #expect(model.branch == "main")
    }

    @Test("control characters are sanitized for display but the raw path is copied")
    func controlCharactersAreSanitizedForDisplayOnly() throws {
        let fixture = try PathBarFixture()
        defer { fixture.cleanup() }
        // A real on-disk directory whose name contains a tab. Sanitizing the
        // path *before* the filesystem lookup (the old bug) would have statted
        // the wrong directory; the layering fix keeps the raw bytes for I/O.
        let badDirectory = fixture.home.appending(path: "bad\tpath")
        try FileManager.default.createDirectory(at: badDirectory, withIntermediateDirectories: true)
        let session = TerminalSession(
            title: "scratch",
            workingDirectory: badDirectory.path,
            agentKind: .shell
        )

        let model = TerminalPathBarModel.make(
            session: session,
            homeDirectory: fixture.home
        )

        // Display is sanitized (tab → space)…
        #expect(!model.path.contains("\t"))
        #expect(model.path == "~/bad path")
        #expect(model.project == "bad path")
        // …but the copyable/revealable path keeps the real bytes so it can `cd`.
        #expect(model.copyPath.contains("\t"))
        #expect(model.copyPath == badDirectory.resolvedPath)
    }

    @Test("trailing space in a directory name is preserved for copy/reveal")
    func trailingSpaceDirectoryNameIsPreserved() throws {
        let fixture = try PathBarFixture()
        defer { fixture.cleanup() }
        let spacedDirectory = fixture.home.appending(path: "Project ")
        try FileManager.default.createDirectory(
            at: spacedDirectory, withIntermediateDirectories: true)
        let session = TerminalSession(
            title: "scratch",
            workingDirectory: spacedDirectory.path,
            agentKind: .shell
        )

        let model = TerminalPathBarModel.make(
            session: session,
            homeDirectory: fixture.home
        )

        // The directory genuinely exists with a trailing space; it must not be
        // trimmed away (which would point copy/reveal at a different folder).
        #expect(model.copyPath.hasSuffix("Project "))
        #expect(model.copyPath == spacedDirectory.resolvedPath)
        #expect(model.branch == nil)
    }

    @Test("home directory itself collapses to a tilde")
    func homeDirectoryCollapsesToTilde() throws {
        let fixture = try PathBarFixture()
        defer { fixture.cleanup() }
        let session = TerminalSession(
            title: "scratch",
            workingDirectory: fixture.home.path,
            agentKind: .shell
        )

        let model = TerminalPathBarModel.make(
            session: session,
            homeDirectory: fixture.home
        )

        #expect(model.path == "~")
        #expect(model.branch == nil)
    }

    @Test("root path renders a single clean segment, not a doubled slash")
    func rootPathRendersSingleSegment() throws {
        let session = TerminalSession(
            title: "root",
            workingDirectory: "/",
            agentKind: .shell
        )

        let model = TerminalPathBarModel.make(session: session)

        #expect(model.project == "/")
        #expect(model.path.isEmpty)
        #expect(model.branch == nil)
    }

    @Test("deleted working directory falls back to a real ancestor, consistently")
    func deletedWorkingDirectoryFallsBackToRealAncestor() throws {
        let fixture = try PathBarFixture()
        defer { fixture.cleanup() }
        let repo = try fixture.makeRepo(named: "awesomux")
        // build/output was never created — it models a cwd deleted out from
        // under a long-lived shell. Label, copy, and reveal must all agree on
        // the surviving ancestor rather than pointing three different places.
        let deletedDirectory = repo.appending(path: "build/output")
        let session = TerminalSession(
            title: "main",
            workingDirectory: deletedDirectory.path,
            agentKind: .codex
        )

        let model = TerminalPathBarModel.make(
            session: session,
            homeDirectory: fixture.home
        )

        #expect(model.project == "awesomux")
        #expect(model.path == "repo root")
        #expect(model.copyPath == repo.resolvedPath)
        #expect(model.revealURL?.resolvingSymlinksInPath().path == repo.resolvedPath)
        #expect(model.branch == "main")
    }

    @Test("detached head displays a short SHA label")
    func detachedHeadDisplaysShortSHALabel() throws {
        let fixture = try PathBarFixture()
        defer { fixture.cleanup() }
        let repo = try fixture.makeRepo(named: "awesomux", head: "abc1234def5678")
        let session = TerminalSession(
            title: "main",
            workingDirectory: repo.path,
            agentKind: .codex
        )

        let model = TerminalPathBarModel.make(
            session: session,
            homeDirectory: fixture.home
        )

        #expect(model.branch == "@ abc1234")
        // Detached HEAD has no local branch (no PR lookup), but the gitdir is valid
        // so the validated root is set — dirty status still runs on detached HEAD.
        #expect(model.gitBranch == nil)
        #expect(model.validatedRepoRootPath == repo.resolvedPath)
    }

    @Test("non-hex detached head yields no branch chip")
    func nonHexDetachedHeadYieldsNoChip() throws {
        let fixture = try PathBarFixture()
        defer { fixture.cleanup() }
        let repo = try fixture.makeRepo(named: "awesomux", head: "not-a-valid-sha-xyz")
        let session = TerminalSession(
            title: "main",
            workingDirectory: repo.path,
            agentKind: .codex
        )

        let model = TerminalPathBarModel.make(
            session: session,
            homeDirectory: fixture.home
        )

        #expect(model.branch == nil)
    }

    @Test("symbolic ref outside refs/heads shortens to its remote name")
    func remoteSymbolicRefShortens() throws {
        let fixture = try PathBarFixture()
        defer { fixture.cleanup() }
        let repo = try fixture.makeRepo(
            named: "awesomux",
            head: "ref: refs/remotes/origin/main"
        )
        let session = TerminalSession(
            title: "main",
            workingDirectory: repo.path,
            agentKind: .codex
        )

        let model = TerminalPathBarModel.make(
            session: session,
            homeDirectory: fixture.home
        )

        #expect(model.branch == "origin/main")
    }

    @Test("bidi override characters are stripped from the branch label")
    func bidiOverrideStrippedFromBranch() throws {
        let fixture = try PathBarFixture()
        defer { fixture.cleanup() }
        // U+202E (RLO) would visually reverse the chip text — a spoof vector
        // because the branch comes from a (possibly hostile) repo's HEAD.
        let repo = try fixture.makeRepo(
            named: "awesomux",
            head: "ref: refs/heads/main\u{202E}evil"
        )
        let session = TerminalSession(
            title: "main",
            workingDirectory: repo.path,
            agentKind: .codex
        )

        let model = TerminalPathBarModel.make(
            session: session,
            homeDirectory: fixture.home
        )

        let branch = try #require(model.branch)
        #expect(!branch.unicodeScalars.contains { $0.value == 0x202E })
        #expect(branch == "mainevil")
    }

    @Test("oversized HEAD with no newline is read bounded and yields no chip")
    func oversizedHeadIsBounded() throws {
        let fixture = try PathBarFixture()
        defer { fixture.cleanup() }
        let repo = try fixture.makeRepo(named: "awesomux")
        // A multi-KB single line (no newline) of non-hex bytes: the bounded
        // reader must not slurp the whole file, and the non-hex content yields
        // no chip rather than hanging or rendering garbage.
        let huge = String(repeating: "x", count: 200_000)
        try huge.write(
            to: repo.appending(path: ".git/HEAD"),
            atomically: true,
            encoding: .utf8
        )
        let session = TerminalSession(
            title: "main",
            workingDirectory: repo.path,
            agentKind: .codex
        )

        let model = TerminalPathBarModel.make(
            session: session,
            homeDirectory: fixture.home
        )

        #expect(model.branch == nil)
    }

    @Test("worktree gitdir files resolve branch state")
    func worktreeGitdirFileResolvesBranchState() throws {
        let fixture = try PathBarFixture()
        defer { fixture.cleanup() }
        let worktree = fixture.home.appending(path: "Development/awesomux-worktree")
        let gitDirectory = fixture.root.appending(path: "gitdirs/worktree")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
        let dotGit = worktree.appending(path: ".git")
        try "gitdir: \(gitDirectory.path)\n".write(
            to: dotGit,
            atomically: true,
            encoding: .utf8
        )
        // A real worktree admin dir carries HEAD + commondir + a gitdir backlink
        // pointing at the worktree's .git file. The backlink is the containment
        // check that a redirected gitdir can't forge.
        try "ref: refs/heads/feature/path-bar\n".write(
            to: gitDirectory.appending(path: "HEAD"),
            atomically: true,
            encoding: .utf8
        )
        try "../..\n".write(
            to: gitDirectory.appending(path: "commondir"),
            atomically: true,
            encoding: .utf8
        )
        try "\(dotGit.path)\n".write(
            to: gitDirectory.appending(path: "gitdir"),
            atomically: true,
            encoding: .utf8
        )
        let session = TerminalSession(
            title: "main",
            workingDirectory: worktree.path,
            agentKind: .codex
        )

        let model = TerminalPathBarModel.make(
            session: session,
            homeDirectory: fixture.home
        )

        #expect(model.branch == "feature/path-bar")
    }

    @Test("submodule gitdir (objects + refs, no commondir) resolves branch")
    func submoduleGitdirResolvesBranch() throws {
        let fixture = try PathBarFixture()
        defer { fixture.cleanup() }
        let submodule = fixture.home.appending(path: "Development/super/sub")
        let modulesDir = fixture.home.appending(path: "Development/super/.git/modules/sub")
        try FileManager.default.createDirectory(at: submodule, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: modulesDir.appending(path: "objects"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: modulesDir.appending(path: "refs"),
            withIntermediateDirectories: true
        )
        try "gitdir: \(modulesDir.path)\n".write(
            to: submodule.appending(path: ".git"),
            atomically: true,
            encoding: .utf8
        )
        try "ref: refs/heads/sub-branch\n".write(
            to: modulesDir.appending(path: "HEAD"),
            atomically: true,
            encoding: .utf8
        )
        let session = TerminalSession(
            title: "sub",
            workingDirectory: submodule.path,
            agentKind: .codex
        )

        let model = TerminalPathBarModel.make(
            session: session,
            homeDirectory: fixture.home
        )

        #expect(model.branch == "sub-branch")
    }

    @Test("gitdir pointing at a non-git directory is rejected")
    func maliciousGitdirTraversalIsRejected() throws {
        let fixture = try PathBarFixture()
        defer { fixture.cleanup() }
        let repo = fixture.home.appending(path: "Development/evil")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        // A hostile .git redirects at a real directory that is NOT a git admin
        // dir (no HEAD/objects/refs/commondir) — modelling an attacker pointing
        // the read at something like ~/.ssh.
        let secretDirectory = fixture.home.appending(path: ".ssh")
        try FileManager.default.createDirectory(
            at: secretDirectory, withIntermediateDirectories: true)
        try "ref: refs/heads/leaked\n".write(
            to: secretDirectory.appending(path: "HEAD"),
            atomically: true,
            encoding: .utf8
        )
        try "gitdir: \(secretDirectory.path)\n".write(
            to: repo.appending(path: ".git"),
            atomically: true,
            encoding: .utf8
        )
        let session = TerminalSession(
            title: "evil",
            workingDirectory: repo.path,
            agentKind: .codex
        )

        let model = TerminalPathBarModel.make(
            session: session,
            homeDirectory: fixture.home
        )

        // Repo boundary is still recognized (a .git file exists), but no branch
        // is read from the attacker-chosen directory.
        #expect(model.project == "evil")
        #expect(model.branch == nil)
        // The repo root is set for display, but the VALIDATED root — which scopes
        // git/gh subprocesses — must be nil, so we never invoke git on the
        // attacker-shaped `.git`.
        #expect(model.repoRootPath != nil)
        #expect(model.validatedRepoRootPath == nil)
    }

    @Test("a symlinked .git is rejected")
    func symlinkedGitIsRejected() throws {
        let fixture = try PathBarFixture()
        defer { fixture.cleanup() }
        // A real git admin dir living elsewhere, and a second repo whose `.git`
        // is a SYMLINK to it — the redirect a `.git` symlink could exploit.
        let target = try fixture.makeRepo(named: "real")
        let repo = fixture.home.appending(path: "Development/linked")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: repo.appending(path: ".git"),
            withDestinationURL: target.appending(path: ".git")
        )
        let session = TerminalSession(
            title: "linked",
            workingDirectory: repo.path,
            agentKind: .codex
        )

        let model = TerminalPathBarModel.make(session: session, homeDirectory: fixture.home)

        #expect(model.branch == nil)
        #expect(model.validatedRepoRootPath == nil)
    }

    @Test("a worktree admin dir whose backlink doesn't point back is rejected")
    func fakeWorktreeBacklinkIsRejected() throws {
        let fixture = try PathBarFixture()
        defer { fixture.cleanup() }
        // A worktree-shaped admin dir (HEAD + commondir) whose `gitdir` backlink
        // points somewhere OTHER than our repo's `.git` file — the containment
        // check a redirected gitdir can't forge.
        let adminDir = fixture.home.appending(path: "admin")
        try FileManager.default.createDirectory(at: adminDir, withIntermediateDirectories: true)
        try "ref: refs/heads/leaked\n".write(
            to: adminDir.appending(path: "HEAD"), atomically: true, encoding: .utf8
        )
        try "../commondir\n".write(
            to: adminDir.appending(path: "commondir"), atomically: true, encoding: .utf8
        )
        try "/somewhere/else/.git\n".write(
            to: adminDir.appending(path: "gitdir"), atomically: true, encoding: .utf8
        )
        let repo = fixture.home.appending(path: "Development/worktree")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try "gitdir: \(adminDir.path)\n".write(
            to: repo.appending(path: ".git"), atomically: true, encoding: .utf8
        )
        let session = TerminalSession(
            title: "worktree",
            workingDirectory: repo.path,
            agentKind: .codex
        )

        let model = TerminalPathBarModel.make(session: session, homeDirectory: fixture.home)

        #expect(model.branch == nil)
        #expect(model.validatedRepoRootPath == nil)
    }

    @Test("preview does no git resolution — proving render-path work is I/O-free")
    func previewDoesNotResolveGit() throws {
        let fixture = try PathBarFixture()
        defer { fixture.cleanup() }
        let repo = try fixture.makeRepo(named: "awesomux")
        let session = TerminalSession(
            title: "main",
            workingDirectory: repo.path,
            agentKind: .codex
        )

        let preview = TerminalPathBarModel.preview(
            session: session,
            homeDirectory: fixture.home
        )

        // The synchronous first-paint model never reads git — branch stays nil
        // and the project is the literal last path component, not the resolved
        // repo name. (Here they happen to coincide, so assert the I/O-only
        // signal: no branch chip.) The authoritative model fills these in
        // off-thread.
        #expect(preview.branch == nil)
        #expect(preview.project == "awesomux")
    }
}

private final class PathBarFixture {
    let root: URL
    let home: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "awesomux-pathbar-\(UUID().uuidString)")
        home = root.appending(path: "home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    func makeRepo(named name: String, head: String = "ref: refs/heads/main") throws -> URL {
        let repo = home.appending(path: "Development/\(name)")
        let git = repo.appending(path: ".git")
        // A realistic git admin directory: HEAD plus the objects/ and refs/
        // directories the model validates before trusting it.
        try FileManager.default.createDirectory(
            at: git.appending(path: "objects"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: git.appending(path: "refs"),
            withIntermediateDirectories: true
        )
        try "\(head)\n".write(
            to: git.appending(path: "HEAD"),
            atomically: true,
            encoding: .utf8
        )
        return repo
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

extension URL {
    /// The model resolves symlinks (the macOS temp dir lives under
    /// `/var`→`/private/var`), so test expectations compare against the
    /// symlink-resolved, standardized path.
    fileprivate var resolvedPath: String {
        resolvingSymlinksInPath().standardizedFileURL.path
    }
}
