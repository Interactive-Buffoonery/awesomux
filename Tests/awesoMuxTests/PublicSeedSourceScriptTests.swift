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

    private func runGuard(publicText: String) throws -> ShellResult {
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

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [copiedScript.path]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
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
