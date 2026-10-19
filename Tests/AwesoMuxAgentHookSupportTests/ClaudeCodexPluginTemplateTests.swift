import AwesoMuxTestSupport
import Foundation
import Testing
@testable import AwesoMuxAgentHookSupport

/// Schema and validation coverage for the bundled Claude Code / Codex plugin
/// marketplace resources (INT-518). These trees are installable as shipped via
/// the providers' native plugin marketplace flows; OpenCode/Pi stay on the
/// awesoMux provider-owned file installer.
@Suite
struct ClaudeCodexPluginTemplateTests {
    struct HooksManifest: Decodable {
        struct Entry: Decodable {
            struct Command: Decodable {
                let type: String
                let command: String
                let timeout: Int?
            }
            let hooks: [Command]
        }
        let hooks: [String: [Entry]]
    }

    // MARK: - Provider fixtures

    struct Provider {
        let directory: String
        let pluginDirectory: String
        let hookProvider: AgentHookProvider
    }

    static let claude = Provider(
        directory: "claude_code",
        pluginDirectory: "awesomux-runtime-status",
        hookProvider: .claudeCode,
    )

    static let codex = Provider(
        directory: "codex",
        pluginDirectory: "awesomux-codex-status",
        hookProvider: .codex,
    )

    // MARK: - Mapper coverage

    /// Every event the shipped template fires must resolve to a non-nil
    /// `AgentHookEventMapper` mapping. A template that declares an unmapped event
    /// invokes the helper on every occurrence only to log `unknown-event` and emit
    /// nothing, so the sidebar silently loses that telemetry. This binds the
    /// templates to the mapper so the two cannot drift apart.
    @Test(arguments: [claude, codex])
    func everyTemplateEventResolvesToAMapping(_ provider: Provider) throws {
        let raw = try Self.contents(of: Self.hooksManifestRelativePath(provider))
        let manifest = try JSONDecoder().decode(HooksManifest.self, from: Data(raw.utf8))

        for event in manifest.hooks.keys {
            #expect(
                AgentHookEventMapper.event(
                    provider: provider.hookProvider,
                    hookEventName: event
                ) != nil,
                "template event \(event) has no \(provider.hookProvider) mapping"
            )
        }
    }

    // MARK: - Bundled Claude validation (requires `claude` on PATH)

    @Test(.enabled(if: Self.executableOnPath("claude") != nil, "claude CLI not found on PATH"))
    func bundledClaudeMarketplaceValidates() throws {
        let claudeURL = try #require(
            Self.executableOnPath("claude"),
            "claude CLI not found on PATH"
        )

        let marketplace = try Self.providerRootURL(Self.claude)
        let result = try Self.run(claudeURL, arguments: ["plugin", "validate", "--strict", marketplace.path])
        #expect(
            result.exitCode == 0,
            "claude plugin validate failed (exit \(result.exitCode)):\n\(result.stdout)\n\(result.stderr)"
        )
    }

    // MARK: - Bundled Codex round-trip (requires `codex` on PATH)

    /// Codex has no offline `validate`; the equivalent check is a real
    /// marketplace add → plugin add → list round-trip against a throwaway
    /// `CODEX_HOME`. This is also where the Codex-only schema decision
    /// (`.claude-plugin/marketplace.json` + `.codex-plugin/plugin.json`) is
    /// exercised against the actual CLI.
    @Test(.enabled(if: Self.executableOnPath("codex") != nil, "codex CLI not found on PATH"))
    func bundledCodexMarketplaceInstalls() throws {
        let codexURL = try #require(
            Self.executableOnPath("codex"),
            "codex CLI not found on PATH"
        )

        let marketplace = try Self.providerRootURL(Self.codex)

        let codexHome = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("awesomux-codex-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: codexHome) }
        let environment = ["CODEX_HOME": codexHome.path]

        let add = try Self.run(
            codexURL,
            arguments: ["plugin", "marketplace", "add", marketplace.path],
            environment: environment
        )
        #expect(
            add.exitCode == 0,
            "codex marketplace add failed (\(add.exitCode)):\n\(add.stdout)\n\(add.stderr)"
        )

        let install = try Self.run(
            codexURL,
            arguments: ["plugin", "add", "awesomux-codex-status@awesomux-codex"],
            environment: environment
        )
        #expect(
            install.exitCode == 0,
            "codex plugin add failed (\(install.exitCode)):\n\(install.stdout)\n\(install.stderr)"
        )

        let list = try Self.run(
            codexURL,
            arguments: ["plugin", "list", "--json"],
            environment: environment
        )
        #expect(list.exitCode == 0)
        #expect(list.stdout.contains("awesomux-codex-status@awesomux-codex"))
    }

    private static func hooksManifestRelativePath(_ provider: Provider) -> String {
        "\(provider.directory)/plugins/\(provider.pluginDirectory)/hooks/hooks.json"
    }

    // MARK: - Filesystem + process helpers

    private static func contents(of relativePath: String) throws -> String {
        let url = try packageRootURL()
            .appendingPathComponent("Resources/AgentIntegrations")
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func providerRootURL(_ provider: Provider) throws -> URL {
        try packageRootURL()
            .appendingPathComponent("Resources/AgentIntegrations")
            .appendingPathComponent(provider.directory)
    }

    private static func packageRootURL() throws -> URL {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let manifest = root.appendingPathComponent("Package.swift")
        try #require(
            FileManager.default.fileExists(atPath: manifest.path),
            "Package.swift not found at \(manifest.path); the test file likely moved depth"
        )
        return root
    }

    private static func executableOnPath(_ name: String) -> URL? {
        guard let pathValue = ProcessInfo.processInfo.environment["PATH"] else {
            return nil
        }
        for directory in pathValue.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private struct ProcessResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    /// Runs `executable` with output captured to files rather than pipes.
    ///
    /// Pipes would put an unbounded read in front of the bounded wait: a pipe
    /// read only returns at EOF, and EOF only arrives once every writer closes.
    /// A wedged child — or a grandchild that inherited the write end and outlives
    /// its parent — never delivers it, so the deadline below would never be
    /// armed and the hang would be as unbounded as awesomux#207's. Draining the
    /// two pipes concurrently fixes only their mutual deadlock, not this.
    ///
    /// Files have no buffer ceiling, so the child never blocks on `write` and
    /// there is no drain to bound or unwind. The wait is the first thing that
    /// happens after launch, and the output is read once the child is gone.
    ///
    /// On timeout the child is deliberately not signalled, matching
    /// `waitUntilExitEventually`: the reading that produced the timeout is
    /// exactly the one that cannot be trusted to still identify our child. The
    /// capture files are always removed.
    private static func run(
        _ executable: URL,
        arguments: [String],
        environment: [String: String]? = nil
    ) throws -> ProcessResult {
        let fileManager = FileManager.default
        let captureDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("awesomux-hook-capture-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: captureDirectory) }

        let stdoutURL = captureDirectory.appendingPathComponent("stdout")
        let stderrURL = captureDirectory.appendingPathComponent("stderr")
        fileManager.createFile(atPath: stdoutURL.path, contents: nil)
        fileManager.createFile(atPath: stderrURL.path, contents: nil)
        let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdoutHandle.close()
            try? stderrHandle.close()
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle
        try process.run()
        try process.waitUntilExitEventually()
        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: try Data(contentsOf: stdoutURL), as: UTF8.self),
            stderr: String(decoding: try Data(contentsOf: stderrURL), as: UTF8.self)
        )
    }
}
