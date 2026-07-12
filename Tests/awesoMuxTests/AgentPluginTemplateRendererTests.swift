import AwesoMuxConfig
import Foundation
import Testing
@testable import awesoMux

@Suite("Agent plugin template renderer")
struct AgentPluginTemplateRendererTests {
    @Test("renders the Claude marketplace tree and bakes the helper path into hooks")
    func rendersClaudeTreeWithBakedHelperPath() throws {
        try Self.withTemporaryDirectory { support in
            let renderer = Self.renderer(support: support)
            let helper = AgentHookHelperPath(path: "/Applications/awesoMux.app/Contents/MacOS/awesoMuxAgentHook", isDevelopmentBundle: false)

            let rendered = try renderer.render(
                provider: .claudeCode,
                setup: AgentIntegrationSetup(enabled: true, binaryPath: "/opt/homebrew/bin/claude"),
                helperPath: helper
            )

            #expect(rendered.provider == .claudeCode)
            #expect(rendered.helperPath == helper.path)
            #expect(FileManager.default.fileExists(atPath: rendered.marketplaceRootURL.path))
            // The marketplace catalog the CLI installs from must be present at the root.
            let marketplaceURL = rendered.marketplaceRootURL
                .appending(path: ".claude-plugin/marketplace.json")
            #expect(FileManager.default.fileExists(atPath: marketplaceURL.path))

            let hookURL = try #require(rendered.hookConfigURLs.first)
            let hookContents = try String(contentsOf: hookURL, encoding: .utf8)
            // The bare default that relies on PATH must be gone; the absolute
            // path is baked into the assignment fallback, env override intact.
            #expect(!hookContents.contains(AgentPluginTemplateRenderer.helperPlaceholderToken))
            #expect(hookContents.contains("AWESOMUX_AGENT_HOOK=${AWESOMUX_AGENT_HOOK:-'\(helper.path)'};"))
            #expect(hookContents.contains("--provider claude-code"))
        }
    }

    @Test("renders the Codex marketplace tree and bakes the helper path into hooks")
    func rendersCodexTreeWithBakedHelperPath() throws {
        try Self.withTemporaryDirectory { support in
            let renderer = Self.renderer(support: support)
            let helper = AgentHookHelperPath(path: "/Applications/awesoMux.app/Contents/MacOS/awesoMuxAgentHook", isDevelopmentBundle: false)

            let rendered = try renderer.render(
                provider: .codex,
                setup: AgentIntegrationSetup(enabled: true, configHome: "/Users/example/.codex"),
                helperPath: helper
            )

            let pluginManifest = rendered.marketplaceRootURL
                .appending(path: "plugins/awesomux-codex-status/.codex-plugin/plugin.json")
            #expect(FileManager.default.fileExists(atPath: pluginManifest.path))

            let hookURL = try #require(rendered.hookConfigURLs.first)
            let hookContents = try String(contentsOf: hookURL, encoding: .utf8)
            #expect(hookContents.contains("AWESOMUX_AGENT_HOOK=${AWESOMUX_AGENT_HOOK:-'\(helper.path)'};"))
            #expect(hookContents.contains("--provider codex"))
        }
    }

    @Test("renders the Grok plugin tree and bakes the helper path into hooks")
    func rendersGrokTreeWithBakedHelperPath() throws {
        try Self.withTemporaryDirectory { support in
            let renderer = Self.renderer(support: support)
            let helper = AgentHookHelperPath(path: "/Applications/awesoMux.app/Contents/MacOS/awesoMuxAgentHook", isDevelopmentBundle: false)

            let rendered = try renderer.render(
                provider: .grok,
                setup: AgentIntegrationSetup(enabled: true, configHome: "/Users/example/.grok"),
                helperPath: helper
            )

            let marketplaceManifest = rendered.marketplaceRootURL
                .appending(path: ".grok-plugin/marketplace.json")
            let pluginManifest = rendered.marketplaceRootURL
                .appending(path: "plugins/awesomux-grok-status/.grok-plugin/plugin.json")
            #expect(FileManager.default.fileExists(atPath: marketplaceManifest.path))
            #expect(FileManager.default.fileExists(atPath: pluginManifest.path))

            let hookURL = try #require(rendered.hookConfigURLs.first)
            let hookContents = try String(contentsOf: hookURL, encoding: .utf8)
            #expect(hookContents.contains("AWESOMUX_AGENT_HOOK=${AWESOMUX_AGENT_HOOK:-'\(helper.path)'};"))
            #expect(hookContents.contains("--provider grok"))
        }
    }

    @Test("rendering shell-quotes and JSON-escapes the baked helper fallback")
    func renderingEscapesHelperPath() throws {
        try Self.withTemporaryDirectory { support in
            let renderer = Self.renderer(support: support)
            let helper = AgentHookHelperPath(
                path: "/Applications/Awesome's $(bad) App.app/Contents/MacOS/awesoMuxAgentHook",
                isDevelopmentBundle: false
            )

            let rendered = try renderer.render(
                provider: .grok,
                setup: AgentIntegrationSetup(enabled: true),
                helperPath: helper
            )

            let hookURL = try #require(rendered.hookConfigURLs.first)
            let raw = try String(contentsOf: hookURL, encoding: .utf8)
            let command = try Self.firstHookCommand(in: raw)
            let expectedFallback =
                "AWESOMUX_AGENT_HOOK=${AWESOMUX_AGENT_HOOK:-'/Applications/Awesome'\\''s $(bad) App.app/Contents/MacOS/awesoMuxAgentHook'};"
            #expect(command.contains(expectedFallback))
            #expect(command.contains("\"$AWESOMUX_AGENT_HOOK\" --provider grok"))
        }
    }

    @Test("static manifests are copied verbatim from the bundle")
    func staticManifestsCopiedVerbatim() throws {
        try Self.withTemporaryDirectory { support in
            let renderer = Self.renderer(support: support)
            let helper = AgentHookHelperPath(path: "/abs/awesoMuxAgentHook", isDevelopmentBundle: false)

            let rendered = try renderer.render(
                provider: .claudeCode,
                setup: AgentIntegrationSetup(enabled: true),
                helperPath: helper
            )

            // The manifests carry no helper placeholder, so the rendered copies
            // must be byte-identical to the bundled originals.
            for relativePath in [
                ".claude-plugin/marketplace.json",
                "plugins/awesomux-claude-status/.claude-plugin/plugin.json"
            ] {
                let renderedData = try Data(contentsOf: rendered.marketplaceRootURL.appending(path: relativePath))
                let bundledData = try Data(
                    contentsOf: renderer.bundledTreeURL(provider: .claudeCode).appending(path: relativePath)
                )
                #expect(renderedData == bundledData)
            }
        }
    }

    @Test("re-rendering replaces a stale tree rather than merging into it")
    func reRenderReplacesStaleTree() throws {
        try Self.withTemporaryDirectory { support in
            let renderer = Self.renderer(support: support)
            let first = AgentHookHelperPath(path: "/first/awesoMuxAgentHook", isDevelopmentBundle: false)
            let second = AgentHookHelperPath(path: "/second/awesoMuxAgentHook", isDevelopmentBundle: false)
            let setup = AgentIntegrationSetup(enabled: true)

            _ = try renderer.render(provider: .claudeCode, setup: setup, helperPath: first)
            let rendered = try renderer.render(provider: .claudeCode, setup: setup, helperPath: second)

            let hookURL = try #require(rendered.hookConfigURLs.first)
            let hookContents = try String(contentsOf: hookURL, encoding: .utf8)
            #expect(hookContents.contains(second.path))
            #expect(!hookContents.contains(first.path))
        }
    }

    @Test("rendered files and tree root get private permissions")
    func renderedArtifactsArePrivate() throws {
        try Self.withTemporaryDirectory { support in
            let renderer = Self.renderer(support: support)
            let rendered = try renderer.render(
                provider: .claudeCode,
                setup: AgentIntegrationSetup(enabled: true),
                helperPath: AgentHookHelperPath(path: "/abs/awesoMuxAgentHook", isDevelopmentBundle: false)
            )

            #expect(try Self.permissions(at: rendered.marketplaceRootURL) == 0o700)
            let hookURL = try #require(rendered.hookConfigURLs.first)
            #expect(try Self.permissions(at: hookURL) == 0o600)
        }
    }

    @Test("disabled setup cannot render")
    func disabledSetupCannotRender() throws {
        try Self.withTemporaryDirectory { support in
            let renderer = Self.renderer(support: support)
            #expect(throws: AgentPluginTemplateRendererError.providerDisabled(.codex)) {
                try renderer.render(
                    provider: .codex,
                    setup: .defaultValue,
                    helperPath: AgentHookHelperPath(path: "/abs/awesoMuxAgentHook", isDevelopmentBundle: false)
                )
            }
        }
    }

    @Test("a missing bundled tree is reported, not silently rendered empty")
    func missingTemplateTreeThrows() throws {
        try Self.withTemporaryDirectory { support in
            let renderer = AgentPluginTemplateRenderer(
                resourcesDirectoryURL: support.appending(path: "no-resources", directoryHint: .isDirectory),
                supportDirectoryURL: support
            )
            #expect(throws: AgentPluginTemplateRendererError.self) {
                try renderer.render(
                    provider: .claudeCode,
                    setup: AgentIntegrationSetup(enabled: true),
                    helperPath: AgentHookHelperPath(path: "/abs/awesoMuxAgentHook", isDevelopmentBundle: false)
                )
            }
        }
    }

    private static func renderer(support: URL) -> AgentPluginTemplateRenderer {
        AgentPluginTemplateRenderer(
            resourcesDirectoryURL: packageResourcesURL,
            supportDirectoryURL: support
        )
    }

    private static func withTemporaryDirectory(_ operation: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "awesomux-agent-plugin-renderer-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try operation(directory)
    }

    private static func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let rawPermissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        return rawPermissions & 0o777
    }

    private static func firstHookCommand(in raw: String) throws -> String {
        let data = Data(raw.utf8)
        let decoded = try JSONDecoder().decode(HooksManifest.self, from: data)
        let entry = try #require(decoded.hooks.values.first?.first)
        return try #require(entry.hooks.first?.command)
    }

    private struct HooksManifest: Decodable {
        struct Entry: Decodable {
            struct Command: Decodable {
                let command: String
            }

            let hooks: [Command]
        }

        let hooks: [String: [Entry]]
    }

    private static var packageResourcesURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Resources", directoryHint: .isDirectory)
    }
}
