import AwesoMuxTestSupport
import Foundation
import Testing
@testable import awesoMux

@Suite("Local Git repository locator")
struct LocalGitRepositoryLocatorTests {
    enum StartingPointsCase: String, CaseIterable {
        case primaryCheckout
        case missingWorkingDirectory
        case linkedWorktree
        case symlinkedPath
    }

    @Test(arguments: StartingPointsCase.allCases)
    func startingPoints(_ scenario: StartingPointsCase) async throws {
        switch scenario {
        case .primaryCheckout:
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
        case .missingWorkingDirectory:
            let fixture = try GitRepositoryFixture()
            defer { fixture.remove() }
            let missing = fixture.repository.appending(path: "missing/nested", directoryHint: .isDirectory)

            let context = try #require((await Self.makeLocator().locate(startingAt: missing)).context)
            #expect(context.invocationRoot == fixture.repository.resolvingSymlinksInPath())
        case .linkedWorktree:
            let fixture = try GitRepositoryFixture()
            defer { fixture.remove() }
            let linked = fixture.root.appending(path: "linked", directoryHint: .isDirectory)
            try fixture.git(["worktree", "add", "--detach", linked.path], cwd: fixture.repository)

            let locator = Self.makeLocator()
            let primary = try #require((await locator.locate(startingAt: fixture.repository)).context)
            let linkedContext = try #require((await locator.locate(startingAt: linked)).context)
            #expect(linkedContext.invocationRoot == linked.resolvingSymlinksInPath())
            #expect(linkedContext.canonicalCommonGitDirectory == primary.canonicalCommonGitDirectory)
        case .symlinkedPath:
            let fixture = try GitRepositoryFixture()
            defer { fixture.remove() }
            let link = fixture.root.appending(path: "primary-link", directoryHint: .isDirectory)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.repository)

            let locator = Self.makeLocator()
            let direct = try #require((await locator.locate(startingAt: fixture.repository)).context)
            let throughLink = try #require((await locator.locate(startingAt: link)).context)
            #expect(throughLink == direct)
        }
    }

    enum UnsupportedRepositoryCase: String, CaseIterable {
        case bareRepository
        case brokenNestedMetadataDoesNotSelectParentRepository
    }

    @Test(arguments: UnsupportedRepositoryCase.allCases)
    func unsupportedRepository(_ scenario: UnsupportedRepositoryCase) async throws {
        switch scenario {
        case .bareRepository:
            let fixture = try GitRepositoryFixture(initializePrimary: false)
            defer { fixture.remove() }
            let bare = fixture.root.appending(path: "bare.git", directoryHint: .isDirectory)
            try fixture.git(["init", "--bare", bare.path], cwd: fixture.root)

            #expect(await Self.makeLocator().locate(startingAt: bare) == .bareRepository)
        case .brokenNestedMetadataDoesNotSelectParentRepository:
            let fixture = try GitRepositoryFixture()
            defer { fixture.remove() }
            let broken = fixture.repository.appending(path: "broken", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
            try "gitdir: /no/such/git/directory\n".write(
                to: broken.appending(path: ".git"), atomically: false, encoding: .utf8)

            #expect(await Self.makeLocator().locate(startingAt: broken) == .notRepository)
        }
    }

    @Test("the environment scrub prevents retargeting and executable shadowing")
    func environmentScrubRemovesRetargetingVariables() async throws {
        let fixture = try GitRepositoryFixture()
        defer { fixture.remove() }
        let planted = fixture.root.appending(path: "git")
        try "#!/bin/sh\necho shadowed\n".write(to: planted, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: planted.path)
        let scrubbed = BoundedLocalGitCommandRunner.scrubbing([
            "GIT_SSH_COMMAND": "ssh -o ProxyCommand=curl|sh",
            "GIT_CONFIG_COUNT": "1",
            "GIT_DIR": "/tmp/elsewhere/.git",
            "GIT_ASKPASS": "/tmp/steal",
            "PATH": fixture.root.path,
            "HOME": "/Users/someone",
        ])
        // Nothing GIT_-prefixed survives except the two this scrub sets itself.
        #expect(
            scrubbed.keys.filter { $0.hasPrefix("GIT_") }.sorted()
                == ["GIT_PAGER", "GIT_TERMINAL_PROMPT"]
        )
        #expect(scrubbed["GIT_TERMINAL_PROMPT"] == "0")
        #expect(scrubbed["GIT_PAGER"] == "cat")
        #expect(scrubbed["PAGER"] == "cat")
        // Unrelated variables survive: this is a targeted scrub, not a wipe.
        #expect(scrubbed["HOME"] == "/Users/someone")
        let runner = BoundedCommandRunner(
            executableCandidates: ["/usr/bin/env"], timeout: .seconds(30),
            environment: scrubbed)
        let result = await runner.runDetailed(arguments: ["git", "rev-parse", "--show-toplevel"], inDirectory: fixture.repository.path)
        guard case .success(let data) = result else {
            Issue.record("scrubbed git failed: \(result)")
            return
        }
        let discovered = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let actual = try FileManager.default.attributesOfItem(atPath: discovered)
        let expected = try FileManager.default.attributesOfItem(atPath: fixture.repository.path)
        #expect(actual[.systemFileNumber] as? NSNumber == expected[.systemFileNumber] as? NSNumber)
        #expect(actual[.systemNumber] as? NSNumber == expected[.systemNumber] as? NSNumber)
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
