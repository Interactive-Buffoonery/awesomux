import AwesoMuxTestSupport
import Foundation
import Testing
@testable import awesoMux

@Suite("Local Git repository locator")
struct LocalGitRepositoryLocatorTests {
    @Test("locates a primary checkout from a nested directory")
    func primaryCheckout() async throws {
        let fixture = try GitRepositoryFixture()
        defer { fixture.remove() }
        let nested = fixture.repository.appending(path: "one/two", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        let outcome = await Self.makeLocator().locate(startingAt: nested)
        let context = try #require(outcome.context)
        #expect(context.invocationRoot == fixture.repository.resolvingSymlinksInPath())
        #expect(context.displayName == "primary")
        #expect(
            context.canonicalCommonGitDirectory
                == fixture.repository.appending(path: ".git", directoryHint: .isDirectory)
        )
    }

    @Test("a linked worktree shares canonical common-git-dir identity")
    func linkedWorktree() async throws {
        let fixture = try GitRepositoryFixture()
        defer { fixture.remove() }
        let linked = fixture.root.appending(path: "linked", directoryHint: .isDirectory)
        try fixture.git(["worktree", "add", "--detach", linked.path], cwd: fixture.repository)

        let locator = Self.makeLocator()
        let primary = try #require((await locator.locate(startingAt: fixture.repository)).context)
        let linkedContext = try #require((await locator.locate(startingAt: linked)).context)
        #expect(linkedContext.invocationRoot == linked.resolvingSymlinksInPath())
        #expect(linkedContext.canonicalCommonGitDirectory == primary.canonicalCommonGitDirectory)
    }

    @Test("bare repositories are an explicit unsupported outcome")
    func bareRepository() async throws {
        let fixture = try GitRepositoryFixture(initializePrimary: false)
        defer { fixture.remove() }
        let bare = fixture.root.appending(path: "bare.git", directoryHint: .isDirectory)
        try fixture.git(["init", "--bare", bare.path], cwd: fixture.root)

        #expect(await Self.makeLocator().locate(startingAt: bare) == .bareRepository)
    }

    @Test("the innermost repository wins for a repository nested inside another")
    func nestedRepository() async throws {
        let fixture = try GitRepositoryFixture()
        defer { fixture.remove() }
        let nested = fixture.repository.appending(path: "nested", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try fixture.git(["init"], cwd: nested)

        let context = try #require((await Self.makeLocator().locate(startingAt: nested)).context)
        #expect(context.invocationRoot == nested.resolvingSymlinksInPath())
    }

    @Test("a symlinked starting path resolves to the same canonical identity")
    func symlinkedPath() async throws {
        let fixture = try GitRepositoryFixture()
        defer { fixture.remove() }
        let link = fixture.root.appending(path: "primary-link", directoryHint: .isDirectory)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.repository)

        let locator = Self.makeLocator()
        let direct = try #require((await locator.locate(startingAt: fixture.repository)).context)
        let throughLink = try #require((await locator.locate(startingAt: link)).context)
        #expect(throughLink == direct)
    }

    /// Git subprocess latency stretches under full-suite load; the timeout is
    /// an outlier guard here, not the behavior under test.
    private static func makeLocator() -> LocalGitRepositoryLocator {
        LocalGitRepositoryLocator(runner: BoundedLocalGitCommandRunner(timeout: .seconds(30)))
    }
}

private extension GitRepositoryLocationOutcome {
    var context: GitRepositoryContext? {
        guard case .located(let context) = self else { return nil }
        return context
    }
}

private final class GitRepositoryFixture {
    let root: URL
    let repository: URL

    init(initializePrimary: Bool = true) throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "awesomux-worktree-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        repository = root.appending(path: "primary", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if initializePrimary {
            try git(["init", repository.path], cwd: root)
            try git(
                ["-c", "user.name=awesoMux Tests", "-c", "user.email=tests@awesomux.local", "commit", "--allow-empty", "-m", "initial"],
                cwd: repository)
        }
    }

    func git(_ arguments: [String], cwd: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        process.environment = [
            "PATH": "/usr/bin:/bin",
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_PAGER": "cat",
            "PAGER": "cat",
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        try process.waitUntilExitEventually()
        guard process.terminationStatus == 0 else {
            throw FixtureError.gitFailed(arguments, process.terminationStatus)
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private enum FixtureError: Error {
    case gitFailed([String], Int32)
}
