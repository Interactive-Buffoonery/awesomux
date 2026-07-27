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

    private func runGuard(
        publicText: String,
        failingRipgrep: Bool = false,
        purgedDirectory: String? = nil,
        purgedFileText: String = ""
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

        if let purgedDirectory {
            let directory = root.appending(path: purgedDirectory, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(purgedFileText.utf8).write(to: directory.appending(path: "resurrected.md"))
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
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        try process.waitUntilExitEventually()
        return ShellResult(
            status: process.terminationStatus,
            output: String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            error: String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
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
