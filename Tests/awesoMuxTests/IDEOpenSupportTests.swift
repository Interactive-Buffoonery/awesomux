import AppKit
import AwesoMuxCore
import Foundation
import Testing
@testable import awesoMux

@Suite("IDE open support")
struct IDEOpenSupportTests {
    @Test("path target reveals in Finder for Command-click")
    func pathTargetCommandClickRevealsInFinder() {
        #expect(PathBarOpenTargetAction.forClick(modifierFlags: [.command]) == .revealInFinder)
        #expect(PathBarOpenTargetAction.forClick(modifierFlags: []) == .showMenu)
    }

    @Test("installed IDE discovery keeps known-candidate order and skips missing apps")
    func installedIDEDiscoveryKeepsKnownOrder() {
        let appRoot = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let installed = InstalledIDEDiscovery.installed { bundleID in
            switch bundleID {
            case "dev.zed.Zed":
                appRoot.appending(path: "Zed.app")
            case "com.microsoft.VSCode":
                appRoot.appending(path: "Visual Studio Code.app")
            default:
                nil
            }
        }

        #expect(installed.map(\.bundleIdentifier) == [
            "com.microsoft.VSCode",
            "dev.zed.Zed"
        ])
        #expect(installed.map(\.displayName) == [
            "Visual Studio Code",
            "Zed"
        ])
    }

    @Test("extra bundle ids join discovery with a bundle-derived name and no duplicates")
    func extraBundleIdentifiersAreDiscoverable() {
        let appRoot = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let installed = InstalledIDEDiscovery.installed(
            extraBundleIdentifiers: ["com.example.Editor", "com.microsoft.VSCode", "missing.app"],
            resolveApplicationURL: { bundleID in
                switch bundleID {
                case "com.microsoft.VSCode": appRoot.appending(path: "Visual Studio Code.app")
                case "com.example.Editor": appRoot.appending(path: "My Editor.app")
                default: nil
                }
            },
            displayName: { _ in "My Editor" }
        )

        // Known VSCode keeps its allowlist name and is not duplicated even
        // though it also appears in the extras. The custom app uses the
        // bundle-derived name. The unresolved extra is dropped.
        #expect(installed.map(\.bundleIdentifier) == [
            "com.microsoft.VSCode",
            "com.example.Editor"
        ])
        #expect(installed.first(where: { $0.bundleIdentifier == "com.example.Editor" })?.displayName == "My Editor")
    }

    @Test("ordered() applies saved priority first, then falls back to known-IDE order")
    func orderedAppliesPriorityThenFallsBack() {
        let zed = Self.ide("Zed", "dev.zed.Zed")
        let cursor = Self.ide("Cursor", "com.todesktop.230313mzl4w4u92")
        let vscode = Self.ide("Visual Studio Code", "com.microsoft.VSCode")
        let installed = [vscode, cursor, zed]

        // Empty priority keeps the installed (known-IDE) order.
        #expect(
            IDEChoice.ordered(installed: installed, priority: []).map(\.bundleIdentifier)
                == installed.map(\.bundleIdentifier)
        )
        // Partial priority pulls listed ids to the front; the rest follow in
        // their existing order.
        #expect(
            IDEChoice.ordered(installed: installed, priority: [zed.bundleIdentifier])
                .map(\.bundleIdentifier)
                == [zed.bundleIdentifier, vscode.bundleIdentifier, cursor.bundleIdentifier]
        )
        // Full priority reorders exactly.
        #expect(
            IDEChoice.ordered(
                installed: installed,
                priority: [cursor.bundleIdentifier, zed.bundleIdentifier, vscode.bundleIdentifier]
            ).map(\.bundleIdentifier)
                == [cursor.bundleIdentifier, zed.bundleIdentifier, vscode.bundleIdentifier]
        )
        // Uninstalled / duplicate priority entries are ignored without dropping
        // installed IDEs.
        #expect(
            IDEChoice.ordered(
                installed: installed,
                priority: ["missing.bundle", zed.bundleIdentifier, zed.bundleIdentifier]
            ).map(\.bundleIdentifier)
                == [zed.bundleIdentifier, vscode.bundleIdentifier, cursor.bundleIdentifier]
        )
    }

    @Test("IDE next step opens one installed IDE and preselects the priority top in the picker")
    func nextStepDependsOnlyOnOrderedList() {
        let zed = Self.ide("Zed", "dev.zed.Zed")
        let cursor = Self.ide("Cursor", "com.todesktop.230313mzl4w4u92")

        #expect(
            IDEChoice.nextStep(ordered: [cursor, zed])
                == .choose(preselectedBundleIdentifier: cursor.bundleIdentifier)
        )
        #expect(IDEChoice.nextStep(ordered: [zed]) == .open(zed))
        #expect(IDEChoice.nextStep(ordered: []) == .unavailable)
    }

    private static func ide(_ name: String, _ bundleID: String) -> InstalledIDE {
        InstalledIDE(
            displayName: name,
            bundleIdentifier: bundleID,
            applicationURL: URL(fileURLWithPath: "/Applications/\(name).app")
        )
    }

    @Test("target resolution opens the validated git worktree root")
    func targetResolutionUsesValidatedWorktreeRoot() async throws {
        let fixture = try IDEOpenFixture()
        defer { fixture.cleanup() }
        let worktree = try fixture.makeWorktree(named: "awesomux-feature")
        let nestedDirectory = worktree.appending(path: "Sources/awesoMux")
        try FileManager.default.createDirectory(
            at: nestedDirectory,
            withIntermediateDirectories: true
        )
        let session = TerminalSession(
            title: "feature",
            workingDirectory: nestedDirectory.path,
            agentKind: .shell
        )

        let target = await IDEOpenTarget.resolve(session: session, homeDirectory: fixture.home)

        #expect(target?.path == worktree.resolvedPath)
    }

    @Test("path-bar targets only open a repo root when the active cwd still belongs to that model")
    func stalePathBarModelCannotOpenPreviousRepo() async throws {
        let fixture = try IDEOpenFixture()
        defer { fixture.cleanup() }
        let previousWorktree = try fixture.makeWorktree(named: "previous-repo")
        let currentWorktree = try fixture.makeWorktree(named: "current-repo")
        let currentNestedDirectory = currentWorktree.appending(path: "Sources/awesoMux")
        try FileManager.default.createDirectory(
            at: currentNestedDirectory,
            withIntermediateDirectories: true
        )
        let staleModel = makePathBarModel(
            copyPath: previousWorktree.path,
            validatedRepoRootPath: previousWorktree.resolvedPath
        )

        #expect(
            IDEOpenTarget.targetURL(
                from: staleModel,
                activeWorkingDirectory: currentNestedDirectory.path,
                homeDirectory: fixture.home
            ) == nil
        )
    }

    @Test("path-bar targets allow same-repo cwd changes before the model refreshes")
    func pathBarModelCanOpenSameRepoWhenActiveCwdMovedWithinIt() async throws {
        let fixture = try IDEOpenFixture()
        defer { fixture.cleanup() }
        let worktree = try fixture.makeWorktree(named: "same-repo")
        let nestedDirectory = worktree.appending(path: "Sources/awesoMux")
        try FileManager.default.createDirectory(
            at: nestedDirectory,
            withIntermediateDirectories: true
        )
        let model = makePathBarModel(
            copyPath: worktree.path,
            validatedRepoRootPath: worktree.resolvedPath
        )

        let target = IDEOpenTarget.targetURL(
            from: model,
            activeWorkingDirectory: "~/Development/same-repo/Sources/awesoMux",
            homeDirectory: fixture.home
        )

        #expect(target?.path == worktree.resolvedPath)
    }

    @Test("remote active panes are not eligible and do not trigger filesystem resolution")
    func remoteActivePaneIsIneligible() async {
        let localPane = TerminalPane(title: "local", workingDirectory: "/tmp/local")
        let remotePane = TerminalPane(
            title: "remote",
            workingDirectory: "/tmp/stale-local",
            remoteHost: "buildbox"
        )
        let session = TerminalSession(
            title: "remote workspace",
            workingDirectory: "/tmp/local",
            agentKind: .shell,
            layout: .split(TerminalSplit(
                orientation: .vertical,
                first: .pane(localPane),
                second: .pane(remotePane)
            )),
            activePaneID: remotePane.id
        )

        #expect(!IDEOpenTarget.isEligible(session: session))
        #expect(await IDEOpenTarget.resolve(session: session) == nil)
    }

    @Test("fallback cwd targets must pass startup-directory validation before opening in an IDE")
    func fallbackCwdRequiresStartupDirectoryValidation() async {
        let session = TerminalSession(
            title: "root",
            workingDirectory: "/",
            agentKind: .shell
        )

        #expect(await IDEOpenTarget.resolve(session: session) == nil)
    }

    @Test("deleted cwd fallback ancestors are not opened as IDE targets")
    func deletedCwdFallbackAncestorIsNotAnIDETarget() async throws {
        let fixture = try IDEOpenFixture()
        defer { fixture.cleanup() }
        let project = fixture.home.appending(path: "Development/deleted-project")
        try FileManager.default.createDirectory(
            at: project,
            withIntermediateDirectories: true
        )
        try FileManager.default.removeItem(at: project)
        let session = TerminalSession(
            title: "deleted",
            workingDirectory: project.path,
            agentKind: .shell
        )

        #expect(await IDEOpenTarget.resolve(session: session, homeDirectory: fixture.home) == nil)
    }
}

private func makePathBarModel(
    copyPath: String,
    validatedRepoRootPath: String?
) -> TerminalPathBarModel {
    TerminalPathBarModel(
        project: URL(fileURLWithPath: copyPath).lastPathComponent,
        path: "",
        activePaneTitle: "",
        branch: nil,
        revealURL: URL(fileURLWithPath: copyPath, isDirectory: true),
        copyPath: WorkingDirectoryValidator.canonicalizedPath(copyPath),
        repoRootPath: validatedRepoRootPath,
        validatedRepoRootPath: validatedRepoRootPath,
        gitBranch: nil,
        pullRequest: nil,
        gitStatus: nil,
        ciStatus: nil,
        remoteHost: nil,
        remoteConnectionHealth: .active
    )
}

private final class IDEOpenFixture {
    let root: URL
    let home: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "awesomux-ide-open-\(UUID().uuidString)")
        home = root.appending(path: "home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    func makeWorktree(named name: String) throws -> URL {
        let worktree = home.appending(path: "Development/\(name)")
        let gitDirectory = root.appending(path: "gitdirs/\(name)")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
        let dotGit = worktree.appending(path: ".git")
        try "gitdir: \(gitDirectory.path)\n".write(
            to: dotGit,
            atomically: true,
            encoding: .utf8
        )
        try "ref: refs/heads/feature/open-ide\n".write(
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
        return worktree
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private extension URL {
    var resolvedPath: String {
        resolvingSymlinksInPath().standardizedFileURL.path
    }
}
