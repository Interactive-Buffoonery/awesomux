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
            let helper = AgentHookHelperPath(
                path: "/Applications/awesoMux.app/Contents/MacOS/awesoMuxAgentHook", isDevelopmentBundle: false)

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
            // The bare default that relies on PATH must be gone; the baked path
            // is now the second rung of a runtime resolution ladder, env
            // override intact.
            #expect(!hookContents.contains(AgentPluginTemplateRenderer.helperPlaceholderToken))
            let command = try Self.firstHookCommand(in: hookContents)
            Self.expectResolutionLadder(command, bakedPath: helper.path)
            #expect(command.contains("\"$AWESOMUX_AGENT_HOOK\" --provider claude-code"))
        }
    }

    @Test("renders the Codex marketplace tree and bakes the helper path into hooks")
    func rendersCodexTreeWithBakedHelperPath() throws {
        try Self.withTemporaryDirectory { support in
            let renderer = Self.renderer(support: support)
            let helper = AgentHookHelperPath(
                path: "/Applications/awesoMux.app/Contents/MacOS/awesoMuxAgentHook", isDevelopmentBundle: false)

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
            let command = try Self.firstHookCommand(in: hookContents)
            Self.expectResolutionLadder(command, bakedPath: helper.path)
            #expect(command.contains("\"$AWESOMUX_AGENT_HOOK\" --provider codex"))
        }
    }

    @Test("renders the Grok plugin tree and bakes the helper path into hooks")
    func rendersGrokTreeWithBakedHelperPath() throws {
        try Self.withTemporaryDirectory { support in
            let renderer = Self.renderer(support: support)
            let helper = AgentHookHelperPath(
                path: "/Applications/awesoMux.app/Contents/MacOS/awesoMuxAgentHook", isDevelopmentBundle: false)

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
            let command = try Self.firstHookCommand(in: hookContents)
            Self.expectResolutionLadder(command, bakedPath: helper.path)
            #expect(command.contains("\"$AWESOMUX_AGENT_HOOK\" --provider grok"))
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
            // Shell single-quoting survives inside every rung that carries the
            // path, and the whole ladder round-trips through JSON intact.
            let quoted = "'/Applications/Awesome'\\''s $(bad) App.app/Contents/MacOS/awesoMuxAgentHook'"
            #expect(command.contains("elif [ -x \(quoted) ]; then AWESOMUX_AGENT_HOOK=\(quoted);"))
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
                "plugins/awesomux-claude-status/.claude-plugin/plugin.json",
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

    @Test("bakes the installing bundle identifier into the Spotlight fallback")
    func bakesInstallingBundleIdentifier() throws {
        try Self.withTemporaryDirectory { support in
            // A development/worktree install must recover to itself, so the
            // relocation lookup carries the installing bundle's id, not a fixed one.
            let command = try Self.bakedGrokCommand(
                support: support,
                bakedPath: "/abs/awesoMuxAgentHook",
                bundleIdentifier: "com.interactivebuffoonery.awesomux.dev.0123456789ab"
            )
            #expect(command.contains("kMDItemCFBundleIdentifier == 'com.interactivebuffoonery.awesomux.dev.0123456789ab'"))
        }
    }

    @Test("a bundle identifier with shell metacharacters falls back to the production id")
    func unsafeBundleIdentifierFallsBack() throws {
        try Self.withTemporaryDirectory { support in
            let command = try Self.bakedGrokCommand(
                support: support,
                bakedPath: "/abs/awesoMuxAgentHook",
                bundleIdentifier: "com.evil\"$(touch /tmp/awx-pwn)"
            )
            // The injection payload must never reach the baked shell command; the
            // query falls back to the known-safe production identifier.
            #expect(!command.contains("touch /tmp/awx-pwn"))
            #expect(command.contains("kMDItemCFBundleIdentifier == 'com.interactivebuffoonery.awesomux'"))
        }
    }

    @Test("baked command honors the env override, then the baked path, at runtime")
    func bakedCommandResolvesOverrideThenBakedPath() throws {
        try Self.withTemporaryDirectory { work in
            let bakedURL = work.appending(path: "installed.app/Contents/MacOS/awesoMuxAgentHook")
            try Self.makeExecutableHook(at: bakedURL, marker: "BAKED")
            let overrideURL = work.appending(path: "override/awesoMuxAgentHook")
            try Self.makeExecutableHook(at: overrideURL, marker: "OVERRIDE")
            let command = try Self.bakedGrokCommand(support: work, bakedPath: bakedURL.path)

            // A: an explicit override that points at an executable wins.
            let a = try Self.runHook(command: command, in: work, envHook: overrideURL.path, mdfindLines: [])
            #expect(a.exitCode == 0)
            #expect(a.stdout == "OVERRIDE")

            // B: no override -> the render-time baked path runs.
            let b = try Self.runHook(command: command, in: work, envHook: nil, mdfindLines: [])
            #expect(b.exitCode == 0)
            #expect(b.stdout == "BAKED")

            // A stale override (path no longer executable) must not be exec'd; the
            // `-x` guard falls through to the baked path instead of erroring.
            let staleOverride = work.appending(path: "gone/awesoMuxAgentHook").path
            let c = try Self.runHook(command: command, in: work, envHook: staleOverride, mdfindLines: [])
            #expect(c.exitCode == 0)
            #expect(c.stdout == "BAKED")
        }
    }

    @Test("baked command relocates a moved app via Spotlight, iterating candidates, else hints")
    func bakedCommandRelocatesViaSpotlightElseHints() throws {
        try Self.withTemporaryDirectory { work in
            // Baked path is gone (app moved away since install).
            let goneBaked = work.appending(path: "moved-away.app/Contents/MacOS/awesoMuxAgentHook").path
            let command = try Self.bakedGrokCommand(support: work, bakedPath: goneBaked)

            // First indexed candidate has no usable helper; a later one (name with
            // a space) does -> iteration must skip the dead entry and pick the live
            // one rather than stranding it behind a `head -1` pick.
            let deadApp = work.appending(path: "Stale.app")
            try FileManager.default.createDirectory(
                at: deadApp.appending(path: "Contents/MacOS"),
                withIntermediateDirectories: true
            )
            let liveApp = work.appending(path: "Relocated App.app")
            try Self.makeExecutableHook(at: liveApp.appending(path: "Contents/MacOS/awesoMuxAgentHook"), marker: "RELOCATED")

            let resolved = try Self.runHook(
                command: command,
                in: work,
                envHook: nil,
                mdfindLines: [deadApp.path, liveApp.path]
            )
            #expect(resolved.exitCode == 0)
            #expect(resolved.stdout == "RELOCATED")

            // Nothing indexed -> one hint on stderr, non-blocking exit 0, no helper run.
            let hinted = try Self.runHook(command: command, in: work, envHook: nil, mdfindLines: [])
            #expect(hinted.exitCode == 0)
            #expect(hinted.stdout.isEmpty)
            #expect(hinted.stderr.contains("reinstall the awesoMux agent integration"))
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

    /// Asserts the baked command carries the full runtime resolution ladder:
    /// an env override guarded by `-x`, the baked path as the second rung, and a
    /// Spotlight bundle-id fallback that iterates candidates rather than trusting
    /// the first index hit.
    private static func expectResolutionLadder(_ command: String, bakedPath: String) {
        let quoted = "'\(bakedPath.replacingOccurrences(of: "'", with: "'\\''"))'"
        #expect(command.contains("[ -n \"$AWESOMUX_AGENT_HOOK\" ] && [ -x \"$AWESOMUX_AGENT_HOOK\" ]"))
        #expect(command.contains("elif [ -x \(quoted) ]; then AWESOMUX_AGENT_HOOK=\(quoted);"))
        #expect(command.contains("mdfind \"kMDItemCFBundleIdentifier == '"))
        #expect(command.contains("while IFS= read -r app;"))
        #expect(command.contains("exit 0"))
    }

    /// Renders the Grok tree with a chosen baked path / bundle id and returns the
    /// decoded first hook command — the exact string a provider runs through sh.
    private static func bakedGrokCommand(
        support: URL,
        bakedPath: String,
        bundleIdentifier: String = "com.interactivebuffoonery.awesomux"
    ) throws -> String {
        let renderer = AgentPluginTemplateRenderer(
            resourcesDirectoryURL: packageResourcesURL,
            supportDirectoryURL: support,
            bundleIdentifier: bundleIdentifier
        )
        let rendered = try renderer.render(
            provider: .grok,
            setup: AgentIntegrationSetup(enabled: true),
            helperPath: AgentHookHelperPath(path: bakedPath, isDevelopmentBundle: false)
        )
        let hookURL = try #require(rendered.hookConfigURLs.first)
        let raw = try String(contentsOf: hookURL, encoding: .utf8)
        return try firstHookCommand(in: raw)
    }

    private static func makeExecutableHook(at url: URL, marker: String) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "#!/bin/sh\nprintf '%s' '\(marker)'\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private struct HookRun {
        var stdout: String
        var stderr: String
        var exitCode: Int32
    }

    /// Runs the baked command under `/bin/sh` with `mdfind` stubbed via a
    /// prepended `PATH`. Stubbing is mandatory: a real awesoMux install would
    /// otherwise satisfy the Spotlight branch and mask the branch under test.
    /// Shell builtins cover the rest of the ladder, and `/usr/bin:/bin` stays on
    /// `PATH` for anything else.
    private static func runHook(
        command: String,
        in workDir: URL,
        envHook: String?,
        mdfindLines: [String]
    ) throws -> HookRun {
        let stubDir = workDir.appending(path: "stub-bin-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: stubDir, withIntermediateDirectories: true)
        let mdfindURL = stubDir.appending(path: "mdfind")
        let script: String
        if mdfindLines.isEmpty {
            script = "#!/bin/sh\n"
        } else {
            script = "#!/bin/sh\ncat <<'AWX_MDFIND_EOF'\n\(mdfindLines.joined(separator: "\n"))\nAWX_MDFIND_EOF\n"
        }
        try script.write(to: mdfindURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mdfindURL.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        var environment = ["PATH": "\(stubDir.path):/usr/bin:/bin"]
        if let envHook {
            environment["AWESOMUX_AGENT_HOOK"] = envHook
        }
        process.environment = environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()

        let out = String(decoding: outPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let err = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return HookRun(stdout: out, stderr: err, exitCode: process.terminationStatus)
    }
}
