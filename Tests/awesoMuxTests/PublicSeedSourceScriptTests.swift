import AwesoMuxTestSupport
import Foundation
import Testing

@Suite("Public seed source guard")
struct PublicSeedSourceScriptTests {
    @Test("Linear issue links are allowed on the public surface")
    func linearIssueLinksAreAllowed() throws {
        let result = try runGuard(
            publicText: "https://linear.app/interactive-buffoonery/issue/INT-819/example"
        )

        #expect(result.status == 0)
        #expect(result.output.contains("check_public_seed_source: clean."))
    }

    @Test("non-issue Linear workspace links remain rejected")
    func nonIssueLinearWorkspaceLinksRemainRejected() throws {
        let result = try runGuard(
            publicText: "https://linear.app/" + "interactive-buffoonery/project/private-plan"
        )

        #expect(result.status == 1)
        #expect(result.error.contains("non-issue Linear workspace URL"))
    }

    @Test(
        "private repository and maintainer markers remain rejected",
        arguments: [
            "contact@" + "interactivebuffoonery.app",
            "awesomux-" + "private",
            "awesomux-" + "internal",
            "COCKPIT" + "_TOKEN",
            "script/" + "cockpit/run.sh",
            "/Users/" + "sarah/project",
            "serabi" + "@example.com",
            "purple-" + "imac",
            "Jiggy" + "Brain",
        ])
    func privateMarkersRemainRejected(marker: String) throws {
        let result = try runGuard(publicText: marker)

        #expect(result.status == 1)
        #expect(result.error.contains("remains in the public seed surface"))
    }

    @Test("gitignored files remain scanned with no-ignore-vcs")
    func trackedIgnoredFilesRemainScanned() throws {
        let result = try runGuard(
            publicText: "public",
            // Split to avoid triggering the guard's own scan of this file.
            trackedIgnoredText: "/Users/" + "sarah/project"
        )

        #expect(result.status == 1)
        #expect(result.error.contains("real maintainer fixture path or host"))
    }

    @Test("ripgrep execution errors fail the guard")
    func ripgrepExecutionErrorsFailTheGuard() throws {
        let result = try runGuard(publicText: "public", failingRipgrep: true)

        #expect(result.status == 1)
        #expect(result.error.contains("public seed source scan failed"))
        #expect(result.error.contains("simulated rg failure"))
    }

    /// The purged directories are rejected on *existence*, not on content.
    /// Only a third of the files removed in the 2026-07-27 purge matched the
    /// string patterns above, so a content-only scan would have readmitted the
    /// rest unnoticed. The fixture content here is deliberately innocuous: if
    /// this test can only fail when the file contains a flagged string, it is
    /// testing the wrong thing.
    @Test(
        "purged directories are rejected even when their contents are innocuous",
        arguments: ["docs/plans", "docs/superpowers"])
    func purgedDirectoriesRemainRejected(directory: String) throws {
        let result = try runGuard(
            publicText: "public",
            purgedDirectory: directory,
            purgedFileText: "nothing sensitive in here at all"
        )

        #expect(result.status == 1)
        #expect(result.error.contains(directory))
        #expect(result.error.contains("must not be reintroduced"))
    }

    /// `[[ -e ]]` alone is false for a dangling symlink, so a tracked
    /// `docs/superpowers -> nowhere` link would reintroduce the path while
    /// passing an existence check. The guard pairs `-e` with `-L` for that
    /// reason; this pins it.
    @Test(
        "purged directories are rejected when reintroduced as a dangling symlink",
        arguments: ["docs/plans", "docs/superpowers"])
    func purgedDirectoriesRejectedAsDanglingSymlink(directory: String) throws {
        let result = try runGuard(
            publicText: "public",
            purgedDirectory: directory,
            purgedPathKind: .danglingSymlink
        )

        #expect(result.status == 1)
        #expect(result.error.contains(directory))
        #expect(result.error.contains("must not be reintroduced"))
    }

    private enum PurgedPathKind {
        case directory
        case danglingSymlink
    }

    private func runGuard(
        publicText: String,
        failingRipgrep: Bool = false,
        trackedIgnoredText: String? = nil,
        purgedDirectory: String? = nil,
        purgedFileText: String = "",
        purgedPathKind: PurgedPathKind = .directory
    ) throws -> ShellResult {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "awesomux-public-seed-guard-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let scriptDirectory = root.appending(path: "script", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scriptDirectory, withIntermediateDirectories: true)
        let sourceScript = try Self.packageRootURL()
            .appending(path: "script/check_public_seed_source.sh")
        let copiedScript = scriptDirectory.appending(path: "check_public_seed_source.sh")
        try Data(contentsOf: sourceScript).write(to: copiedScript)
        try Data(publicText.utf8).write(to: root.appending(path: "PUBLIC.md"))

        if let trackedIgnoredText {
            try Data("secret-dir/\n".utf8).write(to: root.appending(path: ".gitignore"))
            let ignoredDirectory = root.appending(path: "secret-dir", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(
                at: ignoredDirectory,
                withIntermediateDirectories: true
            )
            try Data(trackedIgnoredText.utf8).write(to: ignoredDirectory.appending(path: "leak.md"))
            try runGit(["init"], at: root)
            // Keep the fixture faithful to the tracked-but-ignored scenario.
            try runGit(["add", "-f", ".gitignore", "secret-dir/leak.md"], at: root)
        }

        if let purgedDirectory {
            let path = root.appending(path: purgedDirectory, directoryHint: .isDirectory)
            switch purgedPathKind {
            case .directory:
                try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
                try Data(purgedFileText.utf8).write(to: path.appending(path: "resurrected.md"))
            case .danglingSymlink:
                try FileManager.default.createDirectory(
                    at: path.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try FileManager.default.createSymbolicLink(
                    atPath: path.path,
                    withDestinationPath: root.appending(path: "no-such-target").path
                )
            }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [copiedScript.path]
        if failingRipgrep {
            let binDirectory = root.appending(path: "bin", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
            let ripgrep = binDirectory.appending(path: "rg")
            try Data("#!/bin/sh\necho 'simulated rg failure' >&2\nexit 2\n".utf8).write(to: ripgrep)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: ripgrep.path
            )
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "\(binDirectory.path):\(environment["PATH"] ?? "")"
            process.environment = environment
        }
        let captured = try captureOutput(of: process)
        return ShellResult(
            status: process.terminationStatus,
            output: captured.stdout,
            error: captured.stderr
        )
    }

    private func runGit(_ arguments: [String], at root: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = root
        try process.run()
        try process.waitUntilExitEventually()
        try #require(process.terminationStatus == 0)
    }

    private static func packageRootURL() throws -> URL {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        try #require(FileManager.default.fileExists(atPath: root.appending(path: "Package.swift").path))
        return root
    }

    private struct ShellResult {
        let status: Int32
        let output: String
        let error: String
    }
}
