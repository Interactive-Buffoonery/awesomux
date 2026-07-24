import Foundation
import Testing
@testable import AwesoMuxAgentHookSupport

/// Schema and validation coverage for the bundled Claude Code / Codex plugin
/// marketplace resources (INT-518). These trees are installable as shipped via
/// the providers' native plugin marketplace flows; OpenCode/Pi stay on the
/// awesoMux provider-owned file installer.
@Suite
struct ClaudeCodexPluginTemplateTests {
    static let legacyHelperPlaceholder = "__AWESOMUX_AGENT_HOOK__"
    static let agentHookFallback = "AWESOMUX_AGENT_HOOK=${AWESOMUX_AGENT_HOOK:-awesoMuxAgentHook}; \"$AWESOMUX_AGENT_HOOK\""

    // MARK: - Local decode structs

    struct Marketplace: Decodable {
        struct Owner: Decodable { let name: String }
        struct Metadata: Decodable {
            let description: String
            let version: String
        }
        struct Plugin: Decodable {
            let name: String
            let description: String
            let version: String
            let source: String
        }

        let name: String
        let owner: Owner
        let metadata: Metadata
        let plugins: [Plugin]
    }

    struct PluginManifest: Decodable {
        let name: String
        let version: String
        let description: String
        // Optional: Claude's manifest omits it (hooks/hooks.json is
        // auto-discovered); Codex still carries it. Declaring both a `hooks`
        // field and the conventional file double-registers the hooks.
        let hooks: String?
    }

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
        let pluginManifestRelativePath: String
        let pluginName: String
        let helperProviderFlag: String
        let hookProvider: AgentHookProvider
        let expectedManifestHooks: String?
        let requiredEvents: [String]
    }

    static let claude = Provider(
        directory: "claude_code",
        pluginDirectory: "awesomux-claude-status",
        pluginManifestRelativePath: ".claude-plugin/plugin.json",
        pluginName: "awesomux-claude-status",
        helperProviderFlag: "--provider claude-code",
        hookProvider: .claudeCode,
        expectedManifestHooks: nil,
        requiredEvents: [
            "SessionStart",
            "UserPromptSubmit",
            "PreToolUse",
            "PermissionRequest",
            "PostToolUse",
            "SubagentStart",
            "SubagentStop",
            "Notification",
            "Stop",
            "SessionEnd",
            "StopFailure",
        ]
    )

    static let codex = Provider(
        directory: "codex",
        pluginDirectory: "awesomux-codex-status",
        pluginManifestRelativePath: ".codex-plugin/plugin.json",
        pluginName: "awesomux-codex-status",
        helperProviderFlag: "--provider codex",
        hookProvider: .codex,
        expectedManifestHooks: "./hooks/hooks.json",
        requiredEvents: [
            "SessionStart",
            "UserPromptSubmit",
            "PreToolUse",
            "PermissionRequest",
            "PostToolUse",
            "SubagentStart",
            "SubagentStop",
            "Stop",
            "SessionEnd",
        ]
    )

    // MARK: - Marketplace schema

    @Test(arguments: [claude, codex])
    func marketplaceDecodesWithRequiredKeys(_ provider: Provider) throws {
        let data = try Self.data(of: "\(provider.directory)/.claude-plugin/marketplace.json")
        let marketplace = try JSONDecoder().decode(Marketplace.self, from: data)

        #expect(!marketplace.name.isEmpty)
        #expect(!marketplace.owner.name.isEmpty)
        #expect(!marketplace.metadata.description.isEmpty)
        #expect(!marketplace.metadata.version.isEmpty)

        let plugin = try #require(marketplace.plugins.first)
        #expect(marketplace.plugins.count == 1)
        #expect(plugin.name == provider.pluginName)
        // Claude/Codex marketplaces are direct-installable. Keep plugin sources
        // relative so provider CLIs can copy the tree without awesoMux rendering.
        #expect(plugin.source == "./plugins/\(provider.pluginDirectory)")
    }

    @Test(arguments: [claude, codex])
    func pluginManifestDecodesWithRequiredKeys(_ provider: Provider) throws {
        let relativePath = "\(provider.directory)/plugins/\(provider.pluginDirectory)/\(provider.pluginManifestRelativePath)"
        let data = try Self.data(of: relativePath)
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)

        #expect(manifest.name == provider.pluginName)
        #expect(!manifest.version.isEmpty)
        #expect(!manifest.description.isEmpty)
        #expect(manifest.hooks == provider.expectedManifestHooks)
    }

    // MARK: - Hooks schema

    @Test(arguments: [claude, codex])
    func hooksManifestCoversRequiredEventsWithRuntimeHelperCommand(_ provider: Provider) throws {
        let raw = try Self.contents(of: Self.hooksManifestRelativePath(provider))
        #expect(!raw.contains(Self.legacyHelperPlaceholder))
        #expect(raw.contains("AWESOMUX_AGENT_HOOK"))
        #expect(raw.contains("awesoMuxAgentHook"))
        #expect(!raw.contains("/Applications"))
        #expect(!raw.contains("/private/tmp"))
        #expect(!raw.contains("Contents/MacOS"))
        #expect(!raw.contains("dist/"))

        let manifest = try JSONDecoder().decode(HooksManifest.self, from: Data(raw.utf8))

        for event in provider.requiredEvents {
            let entries = try #require(manifest.hooks[event], "missing event \(event)")
            let entry = try #require(entries.first)
            let command = try #require(entry.hooks.first)
            #expect(command.type == "command")
            // Helper reads the event from stdin; the command carries the helper
            // fallback plus the provider flag and nothing event-specific.
            #expect(command.command == "\(Self.agentHookFallback) \(provider.helperProviderFlag)")
        }

        #expect(manifest.hooks.count == provider.requiredEvents.count)
    }

    @Test(arguments: [claude, codex])
    func hooksManifestOmitsPerEventArguments(_ provider: Provider) throws {
        let raw = try Self.contents(of: Self.hooksManifestRelativePath(provider))
        let manifest = try JSONDecoder().decode(HooksManifest.self, from: Data(raw.utf8))

        // Each event must invoke the helper with the same provider-only command;
        // no event name or other positional argument may be appended.
        let expected = "\(Self.agentHookFallback) \(provider.helperProviderFlag)"
        for (_, entries) in manifest.hooks {
            for entry in entries {
                for command in entry.hooks {
                    #expect(command.command == expected)
                }
            }
        }
    }

    @Test("Codex SessionEnd timeout is within the provider limit")
    func codexSessionEndTimeoutIsWithinProviderLimit() throws {
        let raw = try Self.contents(of: Self.hooksManifestRelativePath(Self.codex))
        let manifest = try JSONDecoder().decode(HooksManifest.self, from: Data(raw.utf8))
        let entry = try #require(manifest.hooks["SessionEnd"]?.first)
        let command = try #require(entry.hooks.first)

        #expect(command.timeout == 3)
    }

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

    private static func data(of relativePath: String) throws -> Data {
        Data(try contents(of: relativePath).utf8)
    }

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

    private static func run(
        _ executable: URL,
        arguments: [String],
        environment: [String: String]? = nil
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: stdoutData, as: UTF8.self),
            stderr: String(decoding: stderrData, as: UTF8.self)
        )
    }
}
