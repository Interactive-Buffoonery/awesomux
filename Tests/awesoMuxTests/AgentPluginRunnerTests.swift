import AwesoMuxTestSupport
import AwesoMuxConfig
import Foundation
import Testing
@testable import awesoMux

@Suite("Agent plugin runner")
struct AgentPluginRunnerTests {
    // The refs are derived from the real bundled marketplace.json names.
    static let claudeRef = AgentPluginMarketplaceRef(
        marketplaceName: "awesomux-claude", pluginName: "awesomux-claude-status"
    )
    static let codexRef = AgentPluginMarketplaceRef(
        marketplaceName: "awesomux-codex", pluginName: "awesomux-codex-status"
    )
    static let grokRef = AgentPluginMarketplaceRef(
        marketplaceName: "awesomux-grok", pluginName: "awesomux-grok-status"
    )

    // MARK: - Claude status mapping

    @Test("Claude: marketplace/plugin absent maps to not-installed")
    func claudeNotInstalled() async throws {
        try await Self.withRunner { runner, command, _ in
            command.stub(args: ["plugin", "list", "--json"], result: .ok(stdout: "[]"))
            let report = await runner.status(provider: .claudeCode, setup: Self.enabled)
            #expect(report.status == .notInstalled)
        }
    }

    @Test("Claude: entry enabled with no errors maps to enabled")
    func claudeEnabled() async throws {
        try await Self.withRunner { runner, command, _ in
            command.stub(args: ["plugin", "list", "--json"], result: .ok(stdout: Self.claudeList(enabled: true)))
            let report = await runner.status(provider: .claudeCode, setup: Self.enabled)
            #expect(report.status == .enabled)
        }
    }

    @Test("Claude: entry present but disabled maps to disabled")
    func claudeDisabled() async throws {
        try await Self.withRunner { runner, command, _ in
            command.stub(args: ["plugin", "list", "--json"], result: .ok(stdout: Self.claudeList(enabled: false)))
            let report = await runner.status(provider: .claudeCode, setup: Self.enabled)
            #expect(report.status == .disabled)
        }
    }

    @Test("Claude: per-plugin errors map to needs-repair")
    func claudeNeedsRepairOnErrors() async throws {
        try await Self.withRunner { runner, command, _ in
            command.stub(
                args: ["plugin", "list", "--json"],
                result: .ok(stdout: Self.claudeList(enabled: true, errors: ["hooks path missing"]))
            )
            let report = await runner.status(provider: .claudeCode, setup: Self.enabled)
            guard case .needsRepair = report.status else {
                Issue.record("expected needsRepair, got \(report.status)")
                return
            }
        }
    }

    @Test("Claude: missing binary maps to unsupported")
    func claudeUnsupportedWhenAbsent() async throws {
        try await Self.withRunner { runner, command, _ in
            command.stub(args: ["plugin", "list", "--json"], failure: .executableNotFound("claude"))
            let report = await runner.status(provider: .claudeCode, setup: Self.enabled)
            guard case .unsupported = report.status else {
                Issue.record("expected unsupported, got \(report.status)")
                return
            }
        }
    }

    @Test("Claude: non-JSON stdout (no --json support) maps to unsupported")
    func claudeUnsupportedWhenNoJSON() async throws {
        try await Self.withRunner { runner, command, _ in
            command.stub(args: ["plugin", "list", "--json"], result: .ok(stdout: "unknown flag --json"))
            let report = await runner.status(provider: .claudeCode, setup: Self.enabled)
            guard case .unsupported = report.status else {
                Issue.record("expected unsupported, got \(report.status)")
                return
            }
        }
    }

    // MARK: - Codex status mapping

    @Test("Codex: untrusted/modified/unknown map to needs-review")
    func codexNeedsReview() async throws {
        for trust in [HookTrustStatus.untrusted, .modified, .unknown("future-state")] {
            try await Self.withRunner { runner, _, codex in
                codex.setHooksList([Self.codexHook(enabled: true, trust: trust)])
                let report = await runner.status(provider: .codex, setup: Self.enabled)
                guard case .needsReview = report.status else {
                    Issue.record("expected needsReview for \(trust), got \(report.status)")
                    return
                }
            }
        }
    }

    @Test("Codex: trusted + enabled maps to enabled")
    func codexEnabled() async throws {
        try await Self.withRunner { runner, _, codex in
            codex.setHooksList([Self.codexHook(enabled: true, trust: .trusted)])
            let report = await runner.status(provider: .codex, setup: Self.enabled)
            #expect(report.status == .enabled)
        }
    }

    @Test("Codex: enabled:false maps to disabled")
    func codexDisabled() async throws {
        try await Self.withRunner { runner, _, codex in
            codex.setHooksList([Self.codexHook(enabled: false, trust: .trusted)])
            let report = await runner.status(provider: .codex, setup: Self.enabled)
            #expect(report.status == .disabled)
        }
    }

    @Test("Codex: all disabled matching hooks map to disabled")
    func codexAllDisabledHooksMapToDisabled() async throws {
        try await Self.withRunner { runner, _, codex in
            codex.setHooksList([
                Self.codexHook(enabled: false, trust: .trusted, key: "a"),
                Self.codexHook(enabled: false, trust: .trusted, key: "b"),
            ])
            let report = await runner.status(provider: .codex, setup: Self.enabled)
            #expect(report.status == .disabled)
        }
    }

    @Test("Codex: mixed enabled and disabled hooks map to needs-repair")
    func codexMixedEnabledHooksNeedRepair() async throws {
        try await Self.withRunner { runner, _, codex in
            codex.setHooksList([
                Self.codexHook(enabled: true, trust: .trusted, key: "a"),
                Self.codexHook(enabled: false, trust: .trusted, key: "b"),
            ])
            let report = await runner.status(provider: .codex, setup: Self.enabled)
            guard case .needsRepair = report.status else {
                Issue.record("expected needsRepair, got \(report.status)")
                return
            }
        }
    }

    @Test("Codex: a disabled hook outranks an untrusted one as needs-repair")
    func codexDisabledOutranksUntrusted() async throws {
        try await Self.withRunner { runner, _, codex in
            // Genuinely mixed: one hook is enabled-but-untrusted (would map to
            // needsReview on its own) and another is disabled (would map to
            // needsRepair). The disabled-check precedence must win, proving Repair
            // is offered ahead of Approve.
            codex.setHooksList([
                Self.codexHook(enabled: true, trust: .untrusted, key: "a"),
                Self.codexHook(enabled: false, trust: .trusted, key: "b"),
            ])
            let report = await runner.status(provider: .codex, setup: Self.enabled)
            guard case .needsRepair = report.status else {
                Issue.record("expected needsRepair (disabled outranks untrusted), got \(report.status)")
                return
            }
        }
    }

    @Test("Codex: command fallback matches when pluginId is absent")
    func codexCommandFallbackMatches() async throws {
        try await Self.withRunner { runner, _, codex in
            codex.setHooksList([
                Self.codexHook(
                    enabled: true,
                    trust: .trusted,
                    pluginId: nil,
                    command: "/Applications/awesoMux.app/Contents/MacOS/awesoMuxAgentHook --provider codex"
                )
            ])
            let report = await runner.status(provider: .codex, setup: Self.enabled)
            #expect(report.status == .enabled)
        }
    }

    @Test("Codex: no matching hook and no install record maps to not-installed")
    func codexNotInstalled() async throws {
        try await Self.withRunner { runner, _, codex in
            codex.setHooksList([])
            let report = await runner.status(provider: .codex, setup: Self.enabled)
            #expect(report.status == .notInstalled)
        }
    }

    @Test("Codex: a recorded install with no matching hook maps to needs-repair, not not-installed")
    func codexRecordedInstallWithNoHookNeedsRepair() async throws {
        try await Self.withRunner { runner, _, codex in
            let home = FileManager.default.temporaryDirectory
                .appending(path: "codexhome-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: home) }
            let setup = AgentIntegrationSetup(enabled: true, configHome: home.path)

            // We installed it; Codex now reports no matching hook (drift / removed).
            let tree = try runner.renderedTree(provider: .codex, setup: setup)
            let ref = try runner.marketplaceRef(provider: .codex)
            try runner.recordInstall(provider: .codex, setup: setup, tree: tree, ref: ref)
            codex.setHooksList([])

            let report = await runner.status(provider: .codex, setup: setup)
            guard case .needsRepair = report.status else {
                Issue.record("expected needsRepair, got \(report.status)")
                return
            }
        }
    }

    @Test("Codex: allow_managed_hooks_only maps to unsupported")
    func codexManagedHooksOnlyUnsupported() async throws {
        try await Self.withRunner { runner, _, codex in
            let home = FileManager.default.temporaryDirectory
                .appending(path: "codexhome-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: home) }
            try "allow_managed_hooks_only = true\n"
                .write(to: home.appending(path: "requirements.toml"), atomically: true, encoding: .utf8)
            let setup = AgentIntegrationSetup(enabled: true, configHome: home.path)

            // Even a healthy hook is moot under the policy — the environment can't
            // host a user hook at all.
            codex.setHooksList([Self.codexHook(enabled: true, trust: .trusted)])

            let report = await runner.status(provider: .codex, setup: setup)
            guard case .unsupported = report.status else {
                Issue.record("expected unsupported, got \(report.status)")
                return
            }
        }
    }

    @Test("Codex: app-server unavailable maps to unsupported")
    func codexUnsupported() async throws {
        try await Self.withRunner { runner, _, codex in
            codex.setHooksListFailure(.appServerUnavailable(reason: "missing subcommand"))
            let report = await runner.status(provider: .codex, setup: Self.enabled)
            guard case .unsupported = report.status else {
                Issue.record("expected unsupported, got \(report.status)")
                return
            }
        }
    }

    // MARK: - Grok status mapping

    @Test("Grok: plugin absent maps to not-installed")
    func grokNotInstalled() async throws {
        try await Self.withRunner { runner, command, _ in
            command.stub(args: ["plugin", "list", "--json"], result: .ok(stdout: "[]"))
            let report = await runner.status(provider: .grok, setup: Self.enabled)
            #expect(report.status == .notInstalled)
        }
    }

    @Test("Grok: listed plugin with a missing on-disk directory needs repair")
    func grokMissingPluginDirectoryNeedsRepair() async throws {
        try await Self.withRunner { runner, command, _ in
            // CLI claims installed under GROK_HOME but the directory is gone.
            let missing = runner.homeDirectoryURL
                .appending(path: ".grok/installed-plugins/missing-\(UUID().uuidString)", directoryHint: .isDirectory)
            command.stub(
                args: ["plugin", "list", "--json"],
                result: .ok(stdout: Self.grokList(path: missing.path))
            )
            let report = await runner.status(provider: .grok, setup: Self.enabled)
            guard case .needsRepair(let guidance) = report.status else {
                Issue.record("expected needsRepair, got \(report.status)")
                return
            }
            #expect(guidance.localizedCaseInsensitiveContains("directory is missing"))
        }
    }

    @Test("Claude: install-record digest mismatch offers an update, not repair")
    func claudeOutdatedSourceDigestNeedsRepair() async throws {
        try await Self.withRunner { runner, command, _ in
            let setup = Self.enabled
            let tree = try runner.renderedTree(provider: .claudeCode, setup: setup)
            let ref = try runner.marketplaceRef(provider: .claudeCode)
            try runner.recordInstall(provider: .claudeCode, setup: setup, tree: tree, ref: ref)
            try Self.rewriteInstallRecordDigest(runner: runner, provider: .claudeCode, digest: "deadbeef")

            command.stub(
                args: ["plugin", "list", "--json"],
                result: .ok(stdout: Self.claudeList(enabled: true))
            )
            let report = await runner.status(provider: .claudeCode, setup: setup)
            guard case .updateAvailable(let guidance) = report.status else {
                Issue.record("expected updateAvailable, got \(report.status)")
                return
            }
            #expect(guidance.contains("newer awesoMux status plugin"))
        }
    }

    @Test("Codex: install-record digest mismatch offers an update when trusted")
    func codexOutdatedSourceDigestNeedsRepair() async throws {
        try await Self.withRunner { runner, _, codex in
            let setup = Self.enabled
            // Status probes require CODEX_HOME to exist under the runner home.
            try FileManager.default.createDirectory(
                at: runner.homeDirectoryURL.appending(path: ".codex", directoryHint: .isDirectory),
                withIntermediateDirectories: true
            )
            let tree = try runner.renderedTree(provider: .codex, setup: setup)
            let ref = try runner.marketplaceRef(provider: .codex)
            try runner.recordInstall(provider: .codex, setup: setup, tree: tree, ref: ref)
            try Self.rewriteInstallRecordDigest(runner: runner, provider: .codex, digest: "deadbeef")

            codex.setHooksList([Self.codexHook(enabled: true, trust: .trusted)])
            let report = await runner.status(provider: .codex, setup: setup)
            guard case .updateAvailable(let guidance) = report.status else {
                Issue.record("expected updateAvailable, got \(report.status)")
                return
            }
            #expect(guidance.contains("newer awesoMux status plugin"))
        }
    }

    @Test("Grok: install-record digest mismatch offers an update")
    func grokOutdatedSourceDigestNeedsRepair() async throws {
        try await Self.withRunner { runner, command, _ in
            let setup = Self.enabled
            let tree = try runner.renderedTree(provider: .grok, setup: setup)
            let ref = try runner.marketplaceRef(provider: .grok)
            try runner.recordInstall(provider: .grok, setup: setup, tree: tree, ref: ref)
            try Self.rewriteInstallRecordDigest(runner: runner, provider: .grok, digest: "deadbeef")

            let pluginDir = try Self.writeGrokPluginHooks(
                eventNames: Array(GrokInstalledHooksInspector.requiredEventNames),
                homeDirectory: runner.homeDirectoryURL
            )
            command.stub(
                args: ["plugin", "list", "--json"],
                result: .ok(stdout: Self.grokList(path: pluginDir.path))
            )
            let report = await runner.status(provider: .grok, setup: setup)
            guard case .updateAvailable(let guidance) = report.status else {
                Issue.record("expected updateAvailable, got \(report.status)")
                return
            }
            #expect(guidance.contains("newer awesoMux status plugin"))
        }
    }

    @Test("recordInstall stores a source content digest")
    func recordInstallStoresSourceDigest() async throws {
        try await Self.withRunner { runner, _, _ in
            let setup = Self.enabled
            let tree = try runner.renderedTree(provider: .claudeCode, setup: setup)
            let ref = try runner.marketplaceRef(provider: .claudeCode)
            try runner.recordInstall(provider: .claudeCode, setup: setup, tree: tree, ref: ref)
            let digest = runner.installRecord(provider: .claudeCode)?.sourceContentDigest
            #expect(digest != nil)
            #expect(digest?.count == 64)
        }
    }

    @Test("Claude: legacy install record without digest offers a one-time update")
    func claudeLegacyInstallWithoutDigestNeedsRepair() async throws {
        try await Self.withRunner { runner, command, _ in
            let setup = Self.enabled
            let tree = try runner.renderedTree(provider: .claudeCode, setup: setup)
            let ref = try runner.marketplaceRef(provider: .claudeCode)
            try runner.recordInstall(provider: .claudeCode, setup: setup, tree: tree, ref: ref)
            try Self.rewriteInstallRecordDigest(runner: runner, provider: .claudeCode, digest: nil)

            command.stub(
                args: ["plugin", "list", "--json"],
                result: .ok(stdout: Self.claudeList(enabled: true))
            )
            let report = await runner.status(provider: .claudeCode, setup: setup)
            guard case .updateAvailable(let guidance) = report.status else {
                Issue.record("expected updateAvailable, got \(report.status)")
                return
            }
            #expect(guidance.contains("Repair once"))
        }
    }

    // MARK: - Deployed-copy verification (INT-882)

    @Test("Claude: deployed copy matching the current render is enabled despite stale record bookkeeping")
    func claudeDeployedCopyCurrentBeatsStaleDigest() async throws {
        try await Self.withRunner { runner, command, _ in
            let setup = Self.enabled
            let tree = try runner.renderedTree(provider: .claudeCode, setup: setup)
            let ref = try runner.marketplaceRef(provider: .claudeCode)
            try runner.recordInstall(provider: .claudeCode, setup: setup, tree: tree, ref: ref)
            // The record claims an ancient source; reality (the cache copy below)
            // is what Claude actually executes and it matches the fresh render.
            try Self.rewriteInstallRecordDigest(runner: runner, provider: .claudeCode, digest: "deadbeef")

            let cache = runner.homeDirectoryURL
                .appending(path: ".claude/plugins/cache/awesomux-claude/awesomux-claude-status/0.1.0")
            // Deploy the exact bytes the current app renders — the healthy state
            // where only record bookkeeping is stale.
            let renderedHooksURL = tree.hookConfigURLs[0]
            let cacheHooksDir = cache.appending(path: "hooks", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: cacheHooksDir, withIntermediateDirectories: true)
            try Data(contentsOf: renderedHooksURL).write(to: cacheHooksDir.appending(path: "hooks.json"))
            command.stub(
                args: ["plugin", "list", "--json"],
                result: .ok(stdout: Self.claudeList(enabled: true, installPath: cache.path))
            )

            // INT-882 regression: this exact state (record drift + healthy deploy)
            // used to read as a red "Needs repair" on every launch.
            let report = await runner.status(provider: .claudeCode, setup: setup)
            #expect(report.status == .enabled)
        }
    }

    @Test("Claude: functional but outdated deployed copy maps to update-available")
    func claudeOutdatedDeployedCopyMapsToUpdateAvailable() async throws {
        try await Self.withRunner { runner, command, _ in
            let setup = Self.enabled
            let helper = try Self.makeExecutableHelper(in: runner.homeDirectoryURL)

            let cache = runner.homeDirectoryURL
                .appending(path: ".claude/plugins/cache/awesomux-claude/awesomux-claude-status/0.1.0")
            try Self.deployClaudePluginCopy(installPath: cache, command: helper.path)
            command.stub(
                args: ["plugin", "list", "--json"],
                result: .ok(stdout: Self.claudeList(enabled: true, installPath: cache.path))
            )

            let report = await runner.status(provider: .claudeCode, setup: setup)
            guard case .updateAvailable = report.status else {
                Issue.record("expected updateAvailable, got \(report.status)")
                return
            }
        }
    }

    @Test("Claude: deployed copy whose baked helper is gone maps to needs-repair")
    func claudeDeadDeployedHelperMapsToNeedsRepair() async throws {
        try await Self.withRunner { runner, command, _ in
            let setup = Self.enabled
            let cache = runner.homeDirectoryURL
                .appending(path: ".claude/plugins/cache/awesomux-claude/awesomux-claude-status/0.1.0")
            try Self.deployClaudePluginCopy(
                installPath: cache,
                command: "/removed-worktree/dist/awesoMuxAgentHook"
            )
            command.stub(
                args: ["plugin", "list", "--json"],
                result: .ok(stdout: Self.claudeList(enabled: true, installPath: cache.path))
            )

            let report = await runner.status(provider: .claudeCode, setup: setup)
            guard case .needsRepair(let guidance) = report.status else {
                Issue.record("expected needsRepair, got \(report.status)")
                return
            }
            #expect(guidance.localizedCaseInsensitiveContains("repair"))
        }
    }

    @Test("Claude: fresh record with drifted deployed copy still forces uninstall before reinstall")
    func claudeDeployedDriftForcesCleanReinstall() async throws {
        try await Self.withRunner { runner, command, _ in
            command.defaultOutcome = .result(.ok(stdout: ""))
            _ = await runner.enableOrInstall(provider: .claudeCode, setup: Self.enabled)

            // Record bookkeeping is fully current — only the deployed cache copy
            // drifted (the INT-882 shape: app replaced in place, version-keyed
            // cache never re-pulled). The gate must still fire.
            let cache = runner.homeDirectoryURL
                .appending(path: ".claude/plugins/cache/awesomux-claude/awesomux-claude-status/0.1.0")
            let helper = try Self.makeExecutableHelper(in: runner.homeDirectoryURL)
            try Self.deployClaudePluginCopy(installPath: cache, command: helper.path)
            command.stub(
                args: ["plugin", "list", "--json"],
                result: .ok(stdout: Self.claudeList(enabled: true, installPath: cache.path))
            )

            let before = command.invocations.count
            let outcome = await runner.enableOrInstall(provider: .claudeCode, setup: Self.enabled)
            #expect(outcome.status == .enabled)

            let argvs = command.invocations.dropFirst(before).map(\.args)
            #expect(argvs.contains(Self.claudeUninstallArgvExpected))
        }
    }

    @Test("Claude: drifted deployed copy with no install record uninstalls by ref so Repair is never dead")
    func claudeDeployedDriftWithoutRecordStillUninstalls() async throws {
        try await Self.withRunner { runner, command, _ in
            command.defaultOutcome = .result(.ok(stdout: ""))

            // An out-of-band install: the plugin exists in Claude's cache but
            // awesoMux has no record of it. Repair must still replace it.
            let cache = runner.homeDirectoryURL
                .appending(path: ".claude/plugins/cache/awesomux-claude/awesomux-claude-status/0.1.0")
            let helper = try Self.makeExecutableHelper(in: runner.homeDirectoryURL)
            try Self.deployClaudePluginCopy(installPath: cache, command: helper.path)
            command.stub(
                args: ["plugin", "list", "--json"],
                result: .ok(stdout: Self.claudeList(enabled: true, installPath: cache.path))
            )

            let outcome = await runner.enableOrInstall(provider: .claudeCode, setup: Self.enabled)
            #expect(outcome.status == .enabled)

            let argvs = command.invocations.map(\.args)
            #expect(argvs.contains(Self.claudeUninstallArgvExpected))
        }
    }

    @Test("Grok: installed plugin with current CamelCase hooks maps to enabled")
    func grokEnabledWithCurrentHooks() async throws {
        try await Self.withRunner { runner, command, _ in
            let pluginDir = try Self.writeGrokPluginHooks(
                eventNames: Array(GrokInstalledHooksInspector.requiredEventNames),
                homeDirectory: runner.homeDirectoryURL
            )
            command.stub(
                args: ["plugin", "list", "--json"],
                result: .ok(stdout: Self.grokList(path: pluginDir.path))
            )
            let report = await runner.status(provider: .grok, setup: Self.enabled)
            #expect(report.status == .enabled)
        }
    }

    @Test("Grok: installed plugin with legacy snake_case hooks maps to needs-repair")
    func grokStaleSnakeCaseHooksNeedsRepair() async throws {
        try await Self.withRunner { runner, command, _ in
            let pluginDir = try Self.writeGrokPluginHooks(
                eventNames: [
                    "session_start", "user_prompt_submit", "pre_tool_use", "post_tool_use",
                    "subagent_start", "subagent_stop", "permission_denied", "notification",
                    "stop", "session_end", "stop_failure",
                ],
                homeDirectory: runner.homeDirectoryURL
            )
            command.stub(
                args: ["plugin", "list", "--json"],
                result: .ok(stdout: Self.grokList(path: pluginDir.path))
            )
            let report = await runner.status(provider: .grok, setup: Self.enabled)
            guard case .needsRepair(let guidance) = report.status else {
                Issue.record("expected needsRepair, got \(report.status)")
                return
            }
            #expect(guidance.localizedCaseInsensitiveContains("snake_case"))
            #expect(guidance.localizedCaseInsensitiveContains("Repair"))
        }
    }

    @Test("Grok: legacy missing-digest record with structurally stale hooks needs repair, not an update offer")
    func grokLegacyMissingDigestWithStaleHooksNeedsRepair() async throws {
        try await Self.withRunner { runner, command, _ in
            let setup = Self.enabled
            let tree = try runner.renderedTree(provider: .grok, setup: setup)
            let ref = try runner.marketplaceRef(provider: .grok)
            try runner.recordInstall(provider: .grok, setup: setup, tree: tree, ref: ref)
            // Pre-fingerprint install: a record exists but carries no digest.
            try Self.rewriteInstallRecordDigest(runner: runner, provider: .grok, digest: nil)

            // The deployed hooks are the legacy snake_case shape that never runs.
            let pluginDir = try Self.writeGrokPluginHooks(
                eventNames: [
                    "session_start", "user_prompt_submit", "pre_tool_use", "post_tool_use",
                    "subagent_start", "subagent_stop", "permission_denied", "notification",
                    "stop", "session_end", "stop_failure",
                ],
                homeDirectory: runner.homeDirectoryURL
            )
            command.stub(
                args: ["plugin", "list", "--json"],
                result: .ok(stdout: Self.grokList(path: pluginDir.path))
            )

            // Breakage outranks freshness: the missing digest alone must not
            // downgrade a broken install to peach "Update available".
            let report = await runner.status(provider: .grok, setup: setup)
            guard case .needsRepair(let guidance) = report.status else {
                Issue.record("expected needsRepair, got \(report.status)")
                return
            }
            #expect(guidance.localizedCaseInsensitiveContains("snake_case"))
        }
    }

    @Test("Grok: plugin path outside GROK_HOME needs repair")
    func grokPluginPathOutsideHomeNeedsRepair() async throws {
        try await Self.withRunner { runner, command, _ in
            let outside = FileManager.default.temporaryDirectory
                .appending(path: "awesomux-outside-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: outside) }
            let pluginDir = try Self.writeGrokPluginHooks(
                eventNames: Array(GrokInstalledHooksInspector.requiredEventNames),
                homeDirectory: outside
            )
            command.stub(
                args: ["plugin", "list", "--json"],
                result: .ok(stdout: Self.grokList(path: pluginDir.path))
            )
            let report = await runner.status(provider: .grok, setup: Self.enabled)
            guard case .needsRepair(let guidance) = report.status else {
                Issue.record("expected needsRepair, got \(report.status)")
                return
            }
            #expect(guidance.contains("outside GROK_HOME"))
        }
    }

    @Test("Grok: disabled status maps to disabled if the CLI reports it")
    func grokDisabled() async throws {
        try await Self.withRunner { runner, command, _ in
            command.stub(args: ["plugin", "list", "--json"], result: .ok(stdout: Self.grokList(status: "disabled")))
            let report = await runner.status(provider: .grok, setup: Self.enabled)
            #expect(report.status == .disabled)
        }
    }

    @Test("GrokInstalledHooksInspector: current hooks need no repair")
    func grokHooksInspectorAcceptsCurrentEvents() throws {
        let pluginDir = try Self.writeGrokPluginHooks(eventNames: Array(GrokInstalledHooksInspector.requiredEventNames))
        defer { try? FileManager.default.removeItem(at: pluginDir) }
        #expect(GrokInstalledHooksInspector.repairGuidanceIfStale(pluginDirectoryPath: pluginDir.path) == nil)
    }

    @Test("GrokInstalledHooksInspector: snake_case hooks need repair")
    func grokHooksInspectorFlagsSnakeCase() throws {
        let pluginDir = try Self.writeGrokPluginHooks(eventNames: ["session_start", "user_prompt_submit"])
        defer { try? FileManager.default.removeItem(at: pluginDir) }
        let guidance = GrokInstalledHooksInspector.repairGuidanceIfStale(pluginDirectoryPath: pluginDir.path)
        #expect(guidance?.contains("snake_case") == true)
    }

    @Test("GrokInstalledHooksInspector: nil path is not treated as stale")
    func grokHooksInspectorIgnoresNilPath() {
        #expect(GrokInstalledHooksInspector.repairGuidanceIfStale(pluginDirectoryPath: nil) == nil)
    }

    @Test("GrokInstalledHooksInspector: missing absolute directory needs repair")
    func grokHooksInspectorMissingDirectoryNeedsRepair() {
        let guidance = GrokInstalledHooksInspector.repairGuidanceIfStale(
            pluginDirectoryPath: "/tmp/does-not-exist-\(UUID().uuidString)"
        )
        #expect(guidance?.localizedCaseInsensitiveContains("directory is missing") == true)
    }

    @Test("Grok: recorded install with no listed plugin maps to needs-repair")
    func grokRecordedInstallWithNoPluginNeedsRepair() async throws {
        try await Self.withRunner { runner, command, _ in
            let setup = AgentIntegrationSetup(enabled: true)
            let tree = try runner.renderedTree(provider: .grok, setup: setup)
            let ref = try runner.marketplaceRef(provider: .grok)
            try runner.recordInstall(provider: .grok, setup: setup, tree: tree, ref: ref)
            command.stub(args: ["plugin", "list", "--json"], result: .ok(stdout: "[]"))

            let report = await runner.status(provider: .grok, setup: setup)
            guard case .needsRepair = report.status else {
                Issue.record("expected needsRepair, got \(report.status)")
                return
            }
        }
    }

    @Test("Codex: trusted hooks backed by a registered plugin with a dead helper need repair")
    func codexTrustedHooksWithDeadRegisteredHelperNeedRepair() async throws {
        try await Self.withRunner { runner, command, codex in
            let setup = Self.enabled
            try FileManager.default.createDirectory(
                at: runner.homeDirectoryURL.appending(path: ".codex", directoryHint: .isDirectory),
                withIntermediateDirectories: true
            )
            // Codex reports the hook fully healthy — trust and enabled — but the
            // registered plugin copy on disk bakes a helper that no longer exists.
            // Trust hashes are content-keyed, so Codex itself cannot see this.
            let registered = runner.homeDirectoryURL
                .appending(path: ".codex/plugins/cache/awesomux-codex/awesomux-codex-status")
            try FileManager.default.createDirectory(
                at: registered.appending(path: "hooks", directoryHint: .isDirectory),
                withIntermediateDirectories: true
            )
            try Data(
                #"{"hooks":{"pre_tool_use":[{"hooks":[{"type":"command","command":"AWESOMUX_AGENT_HOOK=${AWESOMUX_AGENT_HOOK:-'/gone/dist/awesoMuxAgentHook'}; \"$AWESOMUX_AGENT_HOOK\" --provider codex"}]}]}}"#
                    .utf8
            )
            .write(to: registered.appending(path: "hooks", directoryHint: .isDirectory).appending(path: "hooks.json"))
            command.stub(
                args: ["plugin", "list", "--json"],
                result: .ok(
                    stdout:
                        #"{"installed":[{"pluginId":"awesomux-codex-status@awesomux-codex","source":{"source":"local","path":"\#(registered.path)"}}]}"#
                )
            )

            codex.setHooksList([Self.codexHook(enabled: true, trust: .trusted)])
            let report = await runner.status(provider: .codex, setup: setup)
            guard case .needsRepair(let guidance) = report.status else {
                Issue.record("expected needsRepair, got \(report.status)")
                return
            }
            #expect(guidance.contains("/gone/dist/awesoMuxAgentHook"))
            #expect(guidance.localizedCaseInsensitiveContains("repair"))
        }
    }

    @Test("Codex: an unreadable plugin list does not flip a healthy install to repair")
    func codexUnreadablePluginListFailsOpen() async throws {
        try await Self.withRunner { runner, command, codex in
            let setup = Self.enabled
            try FileManager.default.createDirectory(
                at: runner.homeDirectoryURL.appending(path: ".codex", directoryHint: .isDirectory),
                withIntermediateDirectories: true
            )
            command.stub(args: ["plugin", "list", "--json"], result: .ok(stdout: "not json"))

            codex.setHooksList([Self.codexHook(enabled: true, trust: .trusted)])
            let report = await runner.status(provider: .codex, setup: setup)
            #expect(report.status == .enabled)
        }
    }

    @Test("Codex: methodNotFound maps to unsupported")
    func codexMethodNotFoundUnsupported() async throws {
        try await Self.withRunner { runner, _, codex in
            codex.setHooksListFailure(.methodNotFound(method: "hooks/list"))
            let report = await runner.status(provider: .codex, setup: Self.enabled)
            guard case .unsupported = report.status else {
                Issue.record("expected unsupported, got \(report.status)")
                return
            }
        }
    }

    @Test("Codex: configured-but-missing CODEX_HOME maps to needs-repair pointing at the field")
    func codexMissingHomeNeedsRepair() async throws {
        try await Self.withRunner { runner, _, codex in
            codex.setHooksList([Self.codexHook(enabled: true, trust: .trusted)])
            let setup = AgentIntegrationSetup(enabled: true, configHome: "/nonexistent/codex/home/\(UUID().uuidString)")
            let report = await runner.status(provider: .codex, setup: setup)
            guard case .needsRepair(let guidance) = report.status else {
                Issue.record("expected needsRepair, got \(report.status)")
                return
            }
            // Repair re-hits the same missing-home guard and no-ops, so the guidance
            // must send the user to the CODEX_HOME field, not Repair.
            #expect(guidance.contains("CODEX_HOME field"))
        }
    }

    @Test("Codex: live CODEX_HOME differing from the recorded home surfaces a drift note")
    func codexConfigHomeDriftSurfacesNote() async throws {
        try await Self.withRunner { runner, _, codex in
            let recordedHome = FileManager.default.temporaryDirectory
                .appending(path: "codexhome-recorded-\(UUID().uuidString)", directoryHint: .isDirectory)
            let liveHome = FileManager.default.temporaryDirectory
                .appending(path: "codexhome-live-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: recordedHome, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: liveHome, withIntermediateDirectories: true)
            defer {
                try? FileManager.default.removeItem(at: recordedHome)
                try? FileManager.default.removeItem(at: liveHome)
            }

            // Record an install against recordedHome, then probe with the field
            // pointing at a different (live) home.
            let recordedSetup = AgentIntegrationSetup(enabled: true, configHome: recordedHome.path)
            let tree = try runner.renderedTree(provider: .codex, setup: recordedSetup)
            let ref = try runner.marketplaceRef(provider: .codex)
            try runner.recordInstall(provider: .codex, setup: recordedSetup, tree: tree, ref: ref)
            codex.setHooksList([Self.codexHook(enabled: true, trust: .trusted)])

            let report = await runner.status(
                provider: .codex,
                setup: AgentIntegrationSetup(enabled: true, configHome: liveHome.path)
            )
            let note = try #require(report.note)
            #expect(note.contains(recordedHome.path))
            #expect(note.contains(liveHome.path))
            #expect(report.hasConfigHomeDrift)
        }
    }

    @Test("Codex: live home matching the recorded home surfaces no drift note")
    func codexNoDriftWhenHomesMatch() async throws {
        try await Self.withRunner { runner, _, codex in
            let home = FileManager.default.temporaryDirectory
                .appending(path: "codexhome-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: home) }
            let setup = AgentIntegrationSetup(enabled: true, configHome: home.path)
            let tree = try runner.renderedTree(provider: .codex, setup: setup)
            let ref = try runner.marketplaceRef(provider: .codex)
            try runner.recordInstall(provider: .codex, setup: setup, tree: tree, ref: ref)
            codex.setHooksList([Self.codexHook(enabled: true, trust: .trusted)])

            let report = await runner.status(provider: .codex, setup: setup)
            #expect(report.note == nil)
            #expect(!report.hasConfigHomeDrift)
        }
    }

    @Test("Claude: live config home differing from the recorded home surfaces a drift note")
    func claudeConfigHomeDriftSurfacesNote() async throws {
        try await Self.withRunner { runner, command, _ in
            let recordedHome = FileManager.default.temporaryDirectory
                .appending(path: "claudehome-recorded-\(UUID().uuidString)", directoryHint: .isDirectory)
            let liveHome = FileManager.default.temporaryDirectory
                .appending(path: "claudehome-live-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: recordedHome, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: liveHome, withIntermediateDirectories: true)
            defer {
                try? FileManager.default.removeItem(at: recordedHome)
                try? FileManager.default.removeItem(at: liveHome)
            }

            // Record an install against recordedHome, then probe with the field
            // pointing at a different (live) home.
            let recordedSetup = AgentIntegrationSetup(enabled: true, configHome: recordedHome.path)
            let tree = try runner.renderedTree(provider: .claudeCode, setup: recordedSetup)
            let ref = try runner.marketplaceRef(provider: .claudeCode)
            try runner.recordInstall(provider: .claudeCode, setup: recordedSetup, tree: tree, ref: ref)
            command.stub(args: ["plugin", "list", "--json"], result: .ok(stdout: Self.claudeList(enabled: true)))

            let report = await runner.status(
                provider: .claudeCode,
                setup: AgentIntegrationSetup(enabled: true, configHome: liveHome.path)
            )
            let note = try #require(report.note)
            #expect(note.contains(recordedHome.path))
            #expect(note.contains(liveHome.path))
        }
    }

    @Test("Claude: live home matching the recorded home surfaces no drift note")
    func claudeNoDriftWhenHomesMatch() async throws {
        try await Self.withRunner { runner, command, _ in
            let home = FileManager.default.temporaryDirectory
                .appending(path: "claudehome-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: home) }
            let setup = AgentIntegrationSetup(enabled: true, configHome: home.path)
            let tree = try runner.renderedTree(provider: .claudeCode, setup: setup)
            let ref = try runner.marketplaceRef(provider: .claudeCode)
            try runner.recordInstall(provider: .claudeCode, setup: setup, tree: tree, ref: ref)
            command.stub(args: ["plugin", "list", "--json"], result: .ok(stdout: Self.claudeList(enabled: true)))

            let report = await runner.status(provider: .claudeCode, setup: setup)
            #expect(report.note == nil)
        }
    }

    // MARK: - Consent boundary

    @Test("a status read performs no mutating CLI or RPC calls")
    func statusReadIsReadOnly() async throws {
        try await Self.withRunner { runner, command, codex in
            command.stub(args: ["plugin", "list", "--json"], result: .ok(stdout: Self.claudeList(enabled: true)))
            _ = await runner.status(provider: .claudeCode, setup: Self.enabled)

            // The only Claude call allowed in a status read is the list probe.
            #expect(!command.invocations.isEmpty)
            for invocation in command.invocations {
                #expect(invocation.args == ["plugin", "list", "--json"])
            }

            codex.setHooksList([Self.codexHook(enabled: true, trust: .trusted)])
            _ = await runner.status(provider: .codex, setup: Self.enabled)
            // Codex status reads hooks/list only; never writes config.
            #expect(codex.batchWriteCalls.isEmpty)
        }
    }

    @Test("confirmation payloads compute without rendering or shelling out")
    func confirmationIsPureData() async throws {
        try await Self.withRunner { runner, command, codex in
            let claude = runner.confirmation(for: .enableOrInstall, provider: .claudeCode, setup: Self.enabled)
            #expect(claude.executablePath == "claude")
            #expect(claude.commandLines.contains("claude plugin validate [generated awesoMux marketplace path]"))
            #expect(claude.commandLines.contains("claude plugin marketplace add [generated awesoMux marketplace path]"))
            #expect(claude.commandLines.contains { $0.contains("awesomux-claude-status@awesomux-claude --scope user") })
            #expect(claude.configTargets.contains { $0.hasSuffix("/settings.json") })

            let codexInstall = runner.confirmation(for: .enableOrInstall, provider: .codex, setup: Self.enabled)
            #expect(
                codexInstall.commandLines.contains {
                    $0.contains("codex plugin marketplace add [generated awesoMux marketplace path]")
                })

            let codexConfirm = runner.confirmation(for: .uninstall, provider: .codex, setup: Self.enabled)
            #expect(codexConfirm.commandLines.contains { $0.contains("awesomux-codex-status@awesomux-codex") })
            #expect(codexConfirm.configTargets.contains { $0.hasSuffix("/config.toml") })

            let grokConfirm = runner.confirmation(for: .enableOrInstall, provider: .grok, setup: Self.enabled)
            #expect(
                grokConfirm.commandLines == [
                    "grok plugin validate [generated awesoMux plugin path]",
                    "grok plugin install [generated awesoMux plugin path] --trust",
                ])
            #expect(grokConfirm.configTargets.isEmpty)

            // No CLI nor RPC was invoked to compute the confirmation.
            #expect(command.invocations.isEmpty)
            #expect(codex.batchWriteCalls.isEmpty)
        }
    }

    @Test("Claude default executable is resolved through PATH by command name")
    func claudeDefaultExecutableUsesToolName() async throws {
        try await Self.withRunner { runner, command, _ in
            command.defaultOutcome = .result(.ok(stdout: Self.claudeList(enabled: true)))

            _ = await runner.status(provider: .claudeCode, setup: Self.enabled)
            _ = await runner.enableOrInstall(provider: .claudeCode, setup: Self.enabled)

            #expect(!command.invocations.isEmpty)
            for invocation in command.invocations {
                #expect(invocation.executable == "claude")
            }
        }
    }

    @Test("Grok default executable is resolved through PATH by command name")
    func grokDefaultExecutableUsesToolName() async throws {
        try await Self.withRunner { runner, command, _ in
            command.defaultOutcome = .result(.ok(stdout: Self.grokList()))

            _ = await runner.status(provider: .grok, setup: Self.enabled)
            _ = await runner.enableOrInstall(provider: .grok, setup: Self.enabled)

            #expect(!command.invocations.isEmpty)
            for invocation in command.invocations {
                #expect(invocation.executable == "grok")
            }
        }
    }

    @Test("Claude custom binary path remains an exact override")
    func claudeCustomBinaryOverridesDefault() async throws {
        try await Self.withRunner { runner, command, _ in
            let setup = AgentIntegrationSetup(enabled: true, binaryPath: "/custom/bin/claude")
            command.defaultOutcome = .result(.ok(stdout: Self.claudeList(enabled: true)))

            let confirmation = runner.confirmation(for: .enableOrInstall, provider: .claudeCode, setup: setup)
            #expect(confirmation.executablePath == "/custom/bin/claude")

            _ = await runner.status(provider: .claudeCode, setup: setup)
            let invocation = try #require(command.invocations.first)
            #expect(invocation.executable == "/custom/bin/claude")
        }
    }

    // MARK: - Action argv

    @Test("Claude enable/install probes, then issues validate, marketplace add, install --scope user in order")
    func claudeInstallArgv() async throws {
        try await Self.withRunner { runner, command, _ in
            command.defaultOutcome = .result(.ok(stdout: ""))
            let outcome = await runner.enableOrInstall(provider: .claudeCode, setup: Self.enabled)
            #expect(outcome.status == .enabled)

            // The read-only presence/deployed-copy probe always leads (INT-882):
            // its installPath feeds the deployed-drift check even when records
            // look fresh.
            let argvs = command.invocations.map(\.args)
            #expect(argvs.count == 4)
            #expect(argvs[0] == ["plugin", "list", "--json"])
            #expect(argvs[1].first == "plugin" && argvs[1][1] == "validate")
            #expect(Array(argvs[2].prefix(3)) == ["plugin", "marketplace", "add"])
            #expect(argvs[3] == ["plugin", "install", "awesomux-claude-status@awesomux-claude", "--scope", "user"])
        }
    }

    @Test("Claude CLI calls honor configured config home")
    func claudeConfigHomeEnvironment() async throws {
        try await Self.withRunner { runner, command, _ in
            command.defaultOutcome = .result(.ok(stdout: Self.claudeList(enabled: true)))
            let setup = AgentIntegrationSetup(
                enabled: true,
                configHome: "/tmp/awesomux-claude-home-\(UUID().uuidString)"
            )

            _ = await runner.status(provider: .claudeCode, setup: setup)
            _ = await runner.enableOrInstall(provider: .claudeCode, setup: setup)
            _ = await runner.disable(provider: .claudeCode, setup: setup)
            _ = await runner.uninstall(provider: .claudeCode, setup: setup)

            #expect(!command.invocations.isEmpty)
            for invocation in command.invocations {
                #expect(invocation.env["CLAUDE_CONFIG_DIR"] == setup.configHome)
            }
        }
    }

    @Test("Grok CLI calls honor configured GROK_HOME")
    func grokConfigHomeEnvironment() async throws {
        try await Self.withRunner { runner, command, _ in
            command.defaultOutcome = .result(.ok(stdout: Self.grokList()))
            let home = FileManager.default.temporaryDirectory
                .appending(path: "grokhome-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: home) }
            let setup = AgentIntegrationSetup(enabled: true, configHome: home.path)

            _ = await runner.status(provider: .grok, setup: setup)
            _ = await runner.enableOrInstall(provider: .grok, setup: setup)
            _ = await runner.disable(provider: .grok, setup: setup)
            _ = await runner.uninstall(provider: .grok, setup: setup)

            #expect(!command.invocations.isEmpty)
            for invocation in command.invocations {
                #expect(invocation.env["GROK_HOME"] == home.path)
            }
        }
    }

    @Test("Claude status uses recorded config home when current setup changes")
    func claudeStatusUsesRecordedConfigHome() async throws {
        try await Self.withRunner { runner, command, _ in
            command.defaultOutcome = .result(.ok(stdout: ""))
            let recordedHome = "/tmp/awesomux-claude-recorded-\(UUID().uuidString)"
            let changedHome = "/tmp/awesomux-claude-changed-\(UUID().uuidString)"

            _ = await runner.enableOrInstall(
                provider: .claudeCode,
                setup: AgentIntegrationSetup(enabled: true, configHome: recordedHome)
            )
            command.stub(args: ["plugin", "list", "--json"], result: .ok(stdout: Self.claudeList(enabled: true)))

            _ = await runner.status(
                provider: .claudeCode,
                setup: AgentIntegrationSetup(enabled: true, configHome: changedHome)
            )

            let statusInvocation = try #require(command.invocations.last)
            #expect(statusInvocation.args == ["plugin", "list", "--json"])
            #expect(statusInvocation.env["CLAUDE_CONFIG_DIR"] == recordedHome)
        }
    }

    @Test("Claude disable issues disable with no scope flag")
    func claudeDisableArgv() async throws {
        try await Self.withRunner { runner, command, _ in
            command.defaultOutcome = .result(.ok(stdout: ""))
            _ = await runner.disable(provider: .claudeCode, setup: Self.enabled)
            let argv = try #require(command.invocations.first?.args)
            #expect(argv == ["plugin", "disable", "awesomux-claude-status@awesomux-claude"])
        }
    }

    @Test("Claude uninstall issues uninstall then marketplace remove, both --scope user")
    func claudeUninstallArgv() async throws {
        try await Self.withRunner { runner, command, _ in
            command.defaultOutcome = .result(.ok(stdout: ""))
            _ = await runner.uninstall(provider: .claudeCode, setup: Self.enabled)
            let argvs = command.invocations.map(\.args)
            #expect(argvs[0] == ["plugin", "uninstall", "awesomux-claude-status@awesomux-claude", "--scope", "user"])
            #expect(argvs[1] == ["plugin", "marketplace", "remove", "awesomux-claude", "--scope", "user"])
        }
    }

    @Test("Grok enable/install validates and installs the generated plugin path")
    func grokInstallArgv() async throws {
        try await Self.withRunner { runner, command, _ in
            command.defaultOutcome = .result(.ok(stdout: ""))
            let outcome = await runner.enableOrInstall(provider: .grok, setup: Self.enabled)
            #expect(outcome.status == .enabled)

            let argvs = command.invocations.map(\.args)
            #expect(argvs.count == 2)
            #expect(Array(argvs[0].prefix(2)) == ["plugin", "validate"])
            #expect(argvs[0].last?.hasSuffix("plugins/awesomux-grok-status") == true)
            #expect(Array(argvs[1].prefix(2)) == ["plugin", "install"])
            #expect(argvs[1].dropLast().last?.hasSuffix("plugins/awesomux-grok-status") == true)
            #expect(argvs[1].last == "--trust")
        }
    }

    @Test("Grok disable and uninstall use plugin name")
    func grokDisableUninstallArgv() async throws {
        try await Self.withRunner { runner, command, _ in
            command.defaultOutcome = .result(.ok(stdout: ""))

            _ = await runner.disable(provider: .grok, setup: Self.enabled)
            _ = await runner.uninstall(provider: .grok, setup: Self.enabled)

            let argvs = command.invocations.map(\.args)
            #expect(argvs[0] == ["plugin", "disable", "awesomux-grok-status"])
            #expect(argvs[1] == ["plugin", "uninstall", "awesomux-grok-status", "--confirm"])
        }
    }

    @Test("Codex enable upserts hooks.state by the exact hooks/list key with reload")
    func codexEnableBatchWrite() async throws {
        try await Self.withRunner { runner, command, codex in
            command.defaultOutcome = .result(.ok(stdout: ""))
            let liveKey = "/home/.codex/config.toml:pre_tool_use:0:0"
            codex.setHooksList([Self.codexHook(enabled: false, trust: .trusted, key: liveKey)])

            _ = await runner.enableOrInstall(provider: .codex, setup: Self.enabled)

            let write = try #require(codex.batchWriteCalls.first)
            #expect(write.reloadUserConfig)
            #expect(write.writes.count == 1)
            #expect(write.writes[0].keyPath == "hooks.state")
            #expect(write.writes[0].mergeStrategy == .upsert)
            // The state object is keyed by the verbatim hooks/list key, enabled true.
            #expect(write.writes[0].value == .object([liveKey: .object(["enabled": .bool(true)])]))
        }
    }

    @Test("Codex enable writes every matching hook key")
    func codexEnableBatchWriteAllMatchingHooks() async throws {
        try await Self.withRunner { runner, command, codex in
            command.defaultOutcome = .result(.ok(stdout: ""))
            let keyA = "/home/.codex/config.toml:pre_tool_use:0:0"
            let keyB = "/home/.codex/config.toml:post_tool_use:0:0"
            codex.setHooksList([
                Self.codexHook(enabled: false, trust: .trusted, key: keyA),
                Self.codexHook(enabled: false, trust: .trusted, key: keyB),
            ])

            _ = await runner.enableOrInstall(provider: .codex, setup: Self.enabled)

            let write = try #require(codex.batchWriteCalls.first?.writes.first)
            #expect(
                write.value
                    == .object([
                        keyA: .object(["enabled": .bool(true)]),
                        keyB: .object(["enabled": .bool(true)]),
                    ]))
        }
    }

    @Test("Codex install records manifest before set-enabled failure")
    func codexInstallRecordsManifestBeforeSetEnabledFailure() async throws {
        try await Self.withRunner { runner, command, codex in
            command.defaultOutcome = .result(.ok(stdout: ""))
            codex.setHooksList([Self.codexHook(enabled: false, trust: .trusted)])
            codex.setBatchWriteFailure(.rpcError(code: -32000, message: "write failed"))

            let outcome = await runner.enableOrInstall(provider: .codex, setup: Self.enabled)

            guard case .needsRepair = outcome.status else {
                Issue.record("expected needsRepair, got \(outcome.status)")
                return
            }
            let record = try #require(runner.loadInstallManifest().record(for: .codex))
            #expect(record.pluginName == "awesomux-codex-status")
            #expect(record.marketplaceName == "awesomux-codex")
        }
    }

    @Test("Codex disable upserts enabled:false; no auto-trust write")
    func codexDisableBatchWrite() async throws {
        try await Self.withRunner { runner, _, codex in
            let liveKey = "/home/.codex/config.toml:pre_tool_use:0:0"
            codex.setHooksList([Self.codexHook(enabled: true, trust: .trusted, key: liveKey)])

            _ = await runner.disable(provider: .codex, setup: Self.enabled)

            let write = try #require(codex.batchWriteCalls.first)
            #expect(write.writes[0].value == .object([liveKey: .object(["enabled": .bool(false)])]))
            // The write only touches enabled; it never sets a trusted_hash.
            if case .object(let outer) = write.writes[0].value,
                case .object(let inner)? = outer[liveKey]
            {
                #expect(inner["enabled"] != nil)
                #expect(inner["trusted_hash"] == nil)
            } else {
                Issue.record("unexpected batchWrite value shape")
            }
        }
    }

    @Test("missing binary messages include attempted executable path")
    func binaryNotFoundMessagesIncludePath() async throws {
        try await Self.withRunner { runner, command, _ in
            command.stub(args: ["plugin", "list", "--json"], failure: .executableNotFound("/missing/claude"))
            let claude = await runner.status(
                provider: .claudeCode,
                setup: AgentIntegrationSetup(enabled: true, binaryPath: "/missing/claude")
            )
            #expect(claude.status.detail.contains("/missing/claude"))

            command.defaultOutcome = .failure(.executableNotFound("/missing/codex"))
            let codex = await runner.enableOrInstall(
                provider: .codex,
                setup: AgentIntegrationSetup(enabled: true, binaryPath: "/missing/codex")
            )
            #expect(codex.status.detail.contains("/missing/codex"))
        }
    }

    @Test("merged tool path keeps safe defaults and appends extras")
    func mergedToolPathKeepsSafeDefaults() async throws {
        try await Self.withRunner { runner, _, _ in
            let path = runner.mergedToolPath(processPath: "/custom/bin:/usr/bin:/bin")
            let entries = path.split(separator: ":").map(String.init)
            let localBin = FileManager.default.homeDirectoryForCurrentUser
                .appending(path: ".local/bin", directoryHint: .isDirectory).path
            #expect(Array(entries.prefix(5)) == [localBin, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"])
            #expect(entries.contains("/custom/bin"))
        }
    }

    @Test("merged tool path dedups the safe defaults against the process PATH")
    func mergedToolPathDedupsDefaults() async throws {
        try await Self.withRunner { runner, _, _ in
            // A process PATH that repeats a safe default must not duplicate it.
            let path = runner.mergedToolPath(processPath: "/usr/bin:/opt/homebrew/bin:/extra")
            let entries = path.split(separator: ":").map(String.init)
            #expect(entries.filter { $0 == "/usr/bin" }.count == 1)
            #expect(entries.filter { $0 == "/opt/homebrew/bin" }.count == 1)
            #expect(entries.contains("/extra"))
        }
    }

    @Test("merged tool path is stable across calls with the default process PATH")
    func mergedToolPathDefaultIsStable() async throws {
        try await Self.withRunner { runner, _, _ in
            // The cached default merge must return the same value every spawn.
            #expect(runner.mergedToolPath() == runner.mergedToolPath())
        }
    }

    @Test("an unavailable install record blocks provider mutation")
    func manifestWriteFailureBlocksMutation() async throws {
        try await Self.withRunner { runner, command, _ in
            try FileManager.default.createDirectory(at: runner.pluginManifestURL, withIntermediateDirectories: true)
            command.defaultOutcome = .result(.ok(stdout: ""))

            let outcome = await runner.enableOrInstall(provider: .claudeCode, setup: Self.enabled)

            guard case .needsRepair(let message) = outcome.status else {
                Issue.record("expected needsRepair, got \(outcome.status)")
                return
            }
            #expect(message.contains("could not be read"))
            #expect(command.invocations.isEmpty)
        }
    }

    @Test("an empty future plugin manifest is backed up and recovered")
    func emptyFuturePluginManifestRecovers() async throws {
        try await Self.withRunner { runner, command, _ in
            try FileManager.default.createDirectory(
                at: runner.pluginManifestURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let unsupportedVersion = AgentPluginInstallManifest.currentVersion + 1
            try Data(#"{"records":[],"version":\#(unsupportedVersion)}"#.utf8)
                .write(to: runner.pluginManifestURL)
            command.defaultOutcome = .result(.ok(stdout: ""))

            let outcome = await runner.enableOrInstall(provider: .claudeCode, setup: Self.enabled)

            #expect(outcome.status == .enabled)
            #expect(runner.installRecord(provider: .claudeCode) != nil)
            let backups = try FileManager.default.contentsOfDirectory(
                at: runner.pluginManifestURL.deletingLastPathComponent(),
                includingPropertiesForKeys: nil
            ).filter {
                $0.lastPathComponent.hasPrefix(
                    "plugin-install-manifest.unsupported-v\(unsupportedVersion).backup"
                )
            }
            #expect(backups.count == 1)
        }
    }

    @Test("a nonempty future plugin manifest blocks provider mutation")
    func nonemptyFuturePluginManifestBlocksMutation() async throws {
        try await Self.withRunner { runner, command, _ in
            let tree = try runner.renderedTree(provider: .claudeCode, setup: Self.enabled)
            try runner.recordInstall(
                provider: .claudeCode,
                setup: Self.enabled,
                tree: tree,
                ref: Self.claudeRef
            )
            var manifest = runner.loadInstallManifest()
            let unsupportedVersion = AgentPluginInstallManifest.currentVersion + 1
            manifest.version = unsupportedVersion
            try JSONEncoder().encode(manifest).write(to: runner.pluginManifestURL)
            command.defaultOutcome = .result(.ok(stdout: ""))

            let outcome = await runner.enableOrInstall(provider: .claudeCode, setup: Self.enabled)

            guard case .needsRepair(let message) = outcome.status else {
                Issue.record("expected needsRepair, got \(outcome.status)")
                return
            }
            #expect(message.contains("format \(unsupportedVersion)"))
            #expect(command.invocations.isEmpty)
        }
    }

    @Test("plugin runners with separate rendered trees share canonical install state")
    func pluginRunnersShareCanonicalInstallState() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "awesomux-plugin-global-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let installState = directory.appending(path: "global", directoryHint: .isDirectory)
        let first = Self.makeRunner(
            renderedSupport: directory.appending(path: "first", directoryHint: .isDirectory),
            installState: installState
        )
        let second = Self.makeRunner(
            renderedSupport: directory.appending(path: "second", directoryHint: .isDirectory),
            installState: installState
        )
        let tree = try first.renderedTree(provider: .codex, setup: Self.enabled)
        try first.recordInstall(provider: .codex, setup: Self.enabled, tree: tree, ref: Self.codexRef)

        #expect(first.pluginManifestURL == second.pluginManifestURL)
        #expect(second.installRecord(provider: .codex)?.pluginRef == Self.codexRef)
        #expect(
            first.renderer.renderedTreeURL(provider: .codex)
                != second.renderer.renderedTreeURL(provider: .codex))
    }

    @Test("a bare-init runner keeps install state beside its rendered tree, out of the installed app's directory")
    func bareInitInstallStateFollowsRuntimeProfile() {
        // INT-882 regression: the default init used to pin every build — dev
        // worktree builds included — to the production support directory while
        // rendering into their own profile directory, so development runs
        // rewrote the installed app's plugin-install manifest and each build
        // saw the other's records as drift. Records must live in the same
        // profile-scoped root the renderer uses.
        let runner = ProcessAgentPluginRunner()
        // By construction the default install state is the rendered tree's own
        // root; assert the persisted artifact paths that follow from it, plus
        // the regression itself. (Renderer-root equality isn't re-asserted
        // here: SessionPersistence's environment is overridden concurrently by
        // other suites, and re-reading it post-init would be racy.)
        #expect(
            runner.pluginManifestURL
                == runner.installStateDirectoryURL.appending(path: "plugin-install-manifest.json"))
        #expect(
            runner.installStateDirectoryURL
                != AppRuntimeProfile.production.supportDirectoryURL
                .appending(path: "AgentIntegrations", directoryHint: .isDirectory))
    }

    @Test("plugin manifest imports legacy development state only when canonical is absent")
    func pluginManifestLegacyImport() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "awesomux-plugin-legacy-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let canonical = directory.appending(path: "canonical", directoryHint: .isDirectory)
        let legacy = directory.appending(path: "legacy", directoryHint: .isDirectory)
        let legacyRunner = Self.makeRunner(renderedSupport: directory.appending(path: "rendered"), installState: legacy)
        let tree = try legacyRunner.renderedTree(provider: .grok, setup: Self.enabled)
        try legacyRunner.recordInstall(provider: .grok, setup: Self.enabled, tree: tree, ref: Self.grokRef)

        let runner = Self.makeRunner(
            renderedSupport: directory.appending(path: "current"),
            installState: canonical,
            legacyInstallState: legacy
        )
        #expect(runner.installRecord(provider: .grok)?.pluginRef == Self.grokRef)

        let canonicalTree = try runner.renderedTree(provider: .codex, setup: Self.enabled)
        try runner.recordInstall(provider: .codex, setup: Self.enabled, tree: canonicalTree, ref: Self.codexRef)
        let replacementTree = try legacyRunner.renderedTree(provider: .claudeCode, setup: Self.enabled)
        try legacyRunner.recordInstall(
            provider: .claudeCode,
            setup: Self.enabled,
            tree: replacementTree,
            ref: Self.claudeRef
        )

        #expect(runner.installRecord(provider: .codex)?.pluginRef == Self.codexRef)
        #expect(runner.installRecord(provider: .claudeCode) == nil)
    }

    @Test("Codex repair confirmation reads legacy install state without importing it")
    func codexRepairConfirmationDoesNotImportLegacyInstallState() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "awesomux-plugin-confirmation-legacy-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let canonical = directory.appending(path: "canonical", directoryHint: .isDirectory)
        let legacy = directory.appending(path: "legacy", directoryHint: .isDirectory)
        let legacyRunner = Self.makeRunner(renderedSupport: directory.appending(path: "legacy-rendered"), installState: legacy)
        let tree = try legacyRunner.renderedTree(provider: .codex, setup: Self.enabled)
        try legacyRunner.recordInstall(provider: .codex, setup: Self.enabled, tree: tree, ref: Self.codexRef)
        try Self.rewriteInstallRecordDigest(runner: legacyRunner, provider: .codex, digest: "deadbeef")

        let runner = Self.makeRunner(
            renderedSupport: directory.appending(path: "current-rendered"),
            installState: canonical,
            legacyInstallState: legacy
        )
        let confirmation = runner.confirmation(for: .repair, provider: .codex, setup: Self.enabled)

        #expect(!FileManager.default.fileExists(atPath: runner.pluginManifestURL.path))
        #expect(
            confirmation.commandLines.contains(
                "CODEX_HOME=\(legacyRunner.homeDirectoryURL.appending(path: ".codex").path) codex plugin remove awesomux-codex-status@awesomux-codex (only when replacing a stale install)"
            ))
    }

    @Test("invalid legacy plugin state does not poison canonical state")
    func invalidLegacyPluginManifestIsIgnored() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "awesomux-plugin-invalid-legacy-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let canonical = directory.appending(path: "canonical", directoryHint: .isDirectory)
        let legacy = directory.appending(path: "legacy", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data(#"{"version":999,"records":[]}"#.utf8).write(
            to: legacy.appending(path: "plugin-install-manifest.json")
        )
        let runner = Self.makeRunner(
            renderedSupport: directory.appending(path: "rendered"),
            installState: canonical,
            legacyInstallState: legacy
        )

        #expect(runner.loadInstallManifest() == .empty)
        #expect(!FileManager.default.fileExists(atPath: runner.pluginManifestURL.path))

        let tree = try runner.renderedTree(provider: .codex, setup: Self.enabled)
        try runner.recordInstall(provider: .codex, setup: Self.enabled, tree: tree, ref: Self.codexRef)
        #expect(runner.installRecord(provider: .codex)?.pluginRef == Self.codexRef)
    }

    @Test("plugin mutation does not reacquire the install-state lock")
    func pluginMutationLoadsManifestAssumingExistingLock() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "awesomux-plugin-nested-lock-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let canonical = directory.appending(path: "canonical", directoryHint: .isDirectory)
        let legacy = directory.appending(path: "legacy", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data(#"{"version":999,"records":[]}"#.utf8).write(
            to: legacy.appending(path: "plugin-install-manifest.json")
        )
        let command = StubCommandRunner()
        command.defaultOutcome = .result(.ok(stdout: ""))
        let runner = Self.makeRunner(
            renderedSupport: directory.appending(path: "rendered", directoryHint: .isDirectory),
            installState: canonical,
            legacyInstallState: legacy,
            command: command
        )

        let outcome = await runner.enableOrInstall(provider: .claudeCode, setup: Self.enabled)

        #expect(outcome.status == .enabled)
        #expect(outcome.guidance?.contains("install record could not be saved") == false)
        #expect(runner.installRecord(provider: .claudeCode)?.pluginRef == Self.claudeRef)
    }

    @Test("plugin mutation reports another awesoMux instance holding global state")
    func pluginMutationLockContention() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "awesomux-plugin-lock-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let installState = directory.appending(path: "global", directoryHint: .isDirectory)
        let command = StubCommandRunner()
        let runner = Self.makeRunner(
            renderedSupport: directory.appending(path: "rendered", directoryHint: .isDirectory),
            installState: installState,
            command: command
        )
        let lockHolder = try Self.startExternalLockHolder(in: installState)
        defer {
            lockHolder.terminate()
            #expect(throws: Never.self) { try lockHolder.waitUntilExitEventually() }
        }

        let outcome = await runner.enableOrInstall(provider: .claudeCode, setup: Self.enabled)

        guard case .needsRepair(let message) = outcome.status else {
            Issue.record("expected needsRepair, got \(outcome.status)")
            return
        }
        #expect(message.contains("Another awesoMux instance is changing agent integrations"))
        #expect(command.invocations.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: runner.pluginManifestURL.path))
    }

    // MARK: - Clean reinstall (INT-651)

    static let staleHelperPath = "/stale/worktree/dist/awesoMuxAgentHook"
    static let freshHelperPath = "/Applications/awesoMux.app/Contents/MacOS/awesoMuxAgentHook"
    static let claudeUninstallArgvExpected =
        ["plugin", "uninstall", "awesomux-claude-status@awesomux-claude", "--scope", "user"]
    static let codexRemoveArgvExpected =
        ["plugin", "remove", "awesomux-codex-status@awesomux-codex"]

    @Test("Codex: a stale recorded digest forces removal before reinstall")
    func codexStaleDigestCleanReinstall() async throws {
        try await Self.withRunner { runner, command, codex in
            command.defaultOutcome = .result(.ok(stdout: ""))
            codex.setHooksList([Self.codexHook(enabled: true, trust: .trusted)])
            _ = await runner.enableOrInstall(provider: .codex, setup: Self.enabled)
            try Self.rewriteInstallRecordDigest(runner: runner, provider: .codex, digest: "deadbeef")
            command.stub(
                args: ["plugin", "list", "--json"],
                result: .ok(stdout: #"{"installed":[{"pluginId":"awesomux-codex-status@awesomux-codex"}]}"#)
            )

            let before = command.invocations.count
            let outcome = await runner.enableOrInstall(provider: .codex, setup: Self.enabled)

            guard case .needsReview = outcome.status else {
                Issue.record("expected needsReview, got \(outcome.status)")
                return
            }
            let argvs = command.invocations.dropFirst(before).map(\.args)
            guard argvs.count == 4 else {
                Issue.record("expected four commands, got \(argvs.count)")
                return
            }
            #expect(argvs[0] == ["plugin", "list", "--json"])
            #expect(argvs[1] == Self.codexRemoveArgvExpected)
            #expect(Array(argvs[2].prefix(3)) == ["plugin", "marketplace", "add"])
            #expect(argvs[3] == ["plugin", "add", "awesomux-codex-status@awesomux-codex"])
        }
    }

    @Test("Codex: stale repair names the recorded and live config homes")
    func codexStaleRepairConfirmationNamesBothHomes() async throws {
        try await Self.withRunner { runner, command, codex in
            command.defaultOutcome = .result(.ok(stdout: ""))
            codex.setHooksList([Self.codexHook(enabled: true, trust: .trusted)])
            let recordedHome = FileManager.default.temporaryDirectory
                .appending(path: "awesomux-codex-recorded-\(UUID().uuidString)", directoryHint: .isDirectory)
            let liveHome = FileManager.default.temporaryDirectory
                .appending(path: "awesomux-codex-live-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: recordedHome, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: liveHome, withIntermediateDirectories: true)
            defer {
                try? FileManager.default.removeItem(at: recordedHome)
                try? FileManager.default.removeItem(at: liveHome)
            }
            _ = await runner.enableOrInstall(
                provider: .codex,
                setup: AgentIntegrationSetup(enabled: true, configHome: recordedHome.path)
            )
            try Self.rewriteInstallRecordDigest(runner: runner, provider: .codex, digest: "deadbeef")

            let confirmation = runner.confirmation(
                for: .repair,
                provider: .codex,
                setup: AgentIntegrationSetup(enabled: true, configHome: liveHome.path)
            )

            #expect(confirmation.configTargets.contains(recordedHome.appending(path: "config.toml").path))
            #expect(confirmation.configTargets.contains(liveHome.appending(path: "config.toml").path))
            #expect(
                confirmation.commandLines.contains(
                    "CODEX_HOME=\(recordedHome.path) codex plugin remove awesomux-codex-status@awesomux-codex (only when replacing a stale install)"
                ))
        }
    }

    @Test("Codex: stale repair skips removal when the old plugin is absent")
    func codexStaleRepairSkipsRemovalWhenPluginIsAbsent() async throws {
        try await Self.withRunner { runner, command, codex in
            command.defaultOutcome = .result(.ok(stdout: ""))
            codex.setHooksList([Self.codexHook(enabled: true, trust: .trusted)])
            _ = await runner.enableOrInstall(provider: .codex, setup: Self.enabled)
            try Self.rewriteInstallRecordDigest(runner: runner, provider: .codex, digest: "deadbeef")
            command.stub(args: ["plugin", "list", "--json"], result: .ok(stdout: #"{"installed":[]}"#))

            let before = command.invocations.count
            let outcome = await runner.enableOrInstall(provider: .codex, setup: Self.enabled)

            guard case .needsReview = outcome.status else {
                Issue.record("expected needsReview, got \(outcome.status)")
                return
            }
            let argvs = command.invocations.dropFirst(before).map(\.args)
            guard argvs.count == 3 else {
                Issue.record("expected three commands, got \(argvs.count)")
                return
            }
            #expect(argvs[0] == ["plugin", "list", "--json"])
            #expect(!argvs.contains(Self.codexRemoveArgvExpected))
            #expect(Array(argvs[1].prefix(3)) == ["plugin", "marketplace", "add"])
            #expect(argvs[2] == ["plugin", "add", "awesomux-codex-status@awesomux-codex"])
        }
    }

    @Test("Codex: stale repair uses the live binary when the recorded binary vanished")
    func codexStaleRepairDeadRecordedBinaryFallsBack() async throws {
        try await Self.withRunner { runner, command, codex in
            command.defaultOutcome = .result(.ok(stdout: ""))
            codex.setHooksList([Self.codexHook(enabled: true, trust: .trusted)])
            _ = await runner.enableOrInstall(
                provider: .codex,
                setup: AgentIntegrationSetup(enabled: true, binaryPath: "/gone/codex")
            )
            try Self.rewriteInstallRecordDigest(runner: runner, provider: .codex, digest: "deadbeef")
            command.stub(
                executable: "/gone/codex",
                args: ["plugin", "list", "--json"],
                failure: .executableNotFound("/gone/codex")
            )

            let confirmation = runner.confirmation(for: .repair, provider: .codex, setup: Self.enabled)
            #expect(
                confirmation.commandLines.contains(
                    "CODEX_HOME=\(runner.homeDirectoryURL.appending(path: ".codex").path) /gone/codex plugin remove awesomux-codex-status@awesomux-codex (falls back to codex if the recorded executable is unavailable) (only when replacing a stale install)"
                ))

            let outcome = await runner.enableOrInstall(provider: .codex, setup: Self.enabled)

            guard case .needsReview = outcome.status else {
                Issue.record("expected needsReview, got \(outcome.status)")
                return
            }
            let removal = try #require(command.invocations.last { $0.args == Self.codexRemoveArgvExpected })
            #expect(removal.executable == "codex")
        }
    }

    @Test("Claude: a stale recorded helper path forces uninstall before reinstall")
    func claudeStaleHelperPathCleanReinstall() async throws {
        try await Self.withRunner { runner, command, _ in
            command.defaultOutcome = .result(.ok(stdout: ""))
            _ = await runner.enableOrInstall(provider: .claudeCode, setup: Self.enabled)
            try Self.rewriteInstallRecord(runner: runner, provider: .claudeCode) {
                $0.helperPath = Self.staleHelperPath
            }
            command.stub(args: ["plugin", "list", "--json"], result: .ok(stdout: Self.claudeList(enabled: true)))

            let before = command.invocations.count
            let outcome = await runner.enableOrInstall(provider: .claudeCode, setup: Self.enabled)
            #expect(outcome.status == .enabled)

            let argvs = command.invocations.dropFirst(before).map(\.args)
            #expect(argvs.count == 5)
            // Read-only presence probe, then validate, then the destructive steps.
            #expect(argvs[0] == ["plugin", "list", "--json"])
            #expect(argvs[1].first == "plugin" && argvs[1][1] == "validate")
            #expect(argvs[2] == Self.claudeUninstallArgvExpected)
            #expect(Array(argvs[3].prefix(3)) == ["plugin", "marketplace", "add"])
            #expect(argvs[4] == ["plugin", "install", "awesomux-claude-status@awesomux-claude", "--scope", "user"])
            // Success rewrote the record with the fresh helper path, so the gate
            // is satisfied afterwards.
            #expect(runner.installRecord(provider: .claudeCode)?.helperPath == Self.freshHelperPath)
        }
    }

    @Test("Claude: a stale or missing recorded digest forces uninstall before reinstall")
    func claudeStaleDigestCleanReinstall() async throws {
        for digest in ["deadbeef", nil] as [String?] {
            try await Self.withRunner { runner, command, _ in
                command.defaultOutcome = .result(.ok(stdout: ""))
                _ = await runner.enableOrInstall(provider: .claudeCode, setup: Self.enabled)
                try Self.rewriteInstallRecordDigest(runner: runner, provider: .claudeCode, digest: digest)
                command.stub(args: ["plugin", "list", "--json"], result: .ok(stdout: Self.claudeList(enabled: true)))

                let before = command.invocations.count
                let outcome = await runner.enableOrInstall(provider: .claudeCode, setup: Self.enabled)
                #expect(outcome.status == .enabled)
                let argvs = command.invocations.dropFirst(before).map(\.args)
                #expect(argvs.contains(Self.claudeUninstallArgvExpected))
            }
        }
    }

    @Test("Claude: a matching install record does not add an uninstall step")
    func claudeMatchingRecordSkipsUninstall() async throws {
        try await Self.withRunner { runner, command, _ in
            command.defaultOutcome = .result(.ok(stdout: Self.claudeList(enabled: true)))
            _ = await runner.enableOrInstall(provider: .claudeCode, setup: Self.enabled)

            let before = command.invocations.count
            let outcome = await runner.enableOrInstall(provider: .claudeCode, setup: Self.enabled)
            #expect(outcome.status == .enabled)

            // The probe runs (deployed-copy check), then the original
            // validate → marketplace-add → install sequence — but no uninstall.
            let argvs = command.invocations.dropFirst(before).map(\.args)
            #expect(argvs.count == 4)
            #expect(argvs.first == ["plugin", "list", "--json"])
            #expect(!argvs.contains { $0.contains("uninstall") })
        }
    }

    @Test("Claude: clean reinstall skips the uninstall when the plugin is already absent")
    func claudeCleanReinstallSkipsUninstallWhenAbsent() async throws {
        try await Self.withRunner { runner, command, _ in
            command.defaultOutcome = .result(.ok(stdout: ""))
            _ = await runner.enableOrInstall(provider: .claudeCode, setup: Self.enabled)
            try Self.rewriteInstallRecord(runner: runner, provider: .claudeCode) {
                $0.helperPath = Self.staleHelperPath
            }
            // Removed out-of-band: nothing to uninstall; install proceeds.
            command.stub(args: ["plugin", "list", "--json"], result: .ok(stdout: "[]"))

            let before = command.invocations.count
            let outcome = await runner.enableOrInstall(provider: .claudeCode, setup: Self.enabled)
            #expect(outcome.status == .enabled)
            let argvs = command.invocations.dropFirst(before).map(\.args)
            #expect(argvs.count == 4)
            #expect(!argvs.contains { $0.contains("uninstall") })
        }
    }

    @Test("Claude: a failed uninstall aborts the reinstall and keeps the stale record")
    func claudeCleanReinstallUninstallFailureAborts() async throws {
        try await Self.withRunner { runner, command, _ in
            command.defaultOutcome = .result(.ok(stdout: ""))
            _ = await runner.enableOrInstall(provider: .claudeCode, setup: Self.enabled)
            try Self.rewriteInstallRecord(runner: runner, provider: .claudeCode) {
                $0.helperPath = Self.staleHelperPath
            }
            command.stub(args: ["plugin", "list", "--json"], result: .ok(stdout: Self.claudeList(enabled: true)))
            command.stub(
                args: Self.claudeUninstallArgvExpected,
                result: CommandResult(exitCode: 1, stdout: "", stderr: "cache is locked")
            )

            let before = command.invocations.count
            let outcome = await runner.enableOrInstall(provider: .claudeCode, setup: Self.enabled)
            guard case .needsRepair = outcome.status else {
                Issue.record("expected needsRepair, got \(outcome.status)")
                return
            }
            // Nothing installed after the failed uninstall, and the record still
            // names the stale helper — the gate re-fires on the next attempt
            // instead of being silenced by a "successful" no-op install.
            let argvs = command.invocations.dropFirst(before).map(\.args)
            #expect(!argvs.contains { Array($0.prefix(2)) == ["plugin", "install"] })
            #expect(!argvs.contains { Array($0.prefix(3)) == ["plugin", "marketplace", "add"] })
            #expect(runner.installRecord(provider: .claudeCode)?.helperPath == Self.staleHelperPath)
        }
    }

    @Test("Claude: clean reinstall uninstalls in the recorded config home and installs in the live one")
    func claudeCleanReinstallEnvSplit() async throws {
        try await Self.withRunner { runner, command, _ in
            command.defaultOutcome = .result(.ok(stdout: ""))
            let recordedHome = "/tmp/awesomux-claude-recorded-\(UUID().uuidString)"
            let liveHome = "/tmp/awesomux-claude-live-\(UUID().uuidString)"
            _ = await runner.enableOrInstall(
                provider: .claudeCode,
                setup: AgentIntegrationSetup(enabled: true, configHome: recordedHome)
            )
            try Self.rewriteInstallRecord(runner: runner, provider: .claudeCode) {
                $0.helperPath = Self.staleHelperPath
            }
            command.stub(args: ["plugin", "list", "--json"], result: .ok(stdout: Self.claudeList(enabled: true)))

            let before = command.invocations.count
            _ = await runner.enableOrInstall(
                provider: .claudeCode,
                setup: AgentIntegrationSetup(enabled: true, configHome: liveHome)
            )
            let invocations = Array(command.invocations.dropFirst(before))
            #expect(invocations.count == 5)
            // Probe + uninstall target the recorded install's home; validate,
            // marketplace add, and install follow the live field.
            #expect(invocations[0].env["CLAUDE_CONFIG_DIR"] == recordedHome)
            #expect(invocations[2].env["CLAUDE_CONFIG_DIR"] == recordedHome)
            #expect(invocations[1].env["CLAUDE_CONFIG_DIR"] == liveHome)
            #expect(invocations[3].env["CLAUDE_CONFIG_DIR"] == liveHome)
            #expect(invocations[4].env["CLAUDE_CONFIG_DIR"] == liveHome)
        }
    }

    @Test("Claude: a failure after the uninstall reports a repairable partial install")
    func claudeCleanReinstallPartialFailureIsRepairable() async throws {
        try await Self.withRunner { runner, command, _ in
            command.defaultOutcome = .result(.ok(stdout: ""))
            _ = await runner.enableOrInstall(provider: .claudeCode, setup: Self.enabled)
            try Self.rewriteInstallRecord(runner: runner, provider: .claudeCode) {
                $0.helperPath = Self.staleHelperPath
            }
            command.stub(args: ["plugin", "list", "--json"], result: .ok(stdout: Self.claudeList(enabled: true)))
            let root = runner.renderer.renderedTreeURL(provider: .claudeCode).path
            command.stub(
                args: ["plugin", "marketplace", "add", root],
                result: CommandResult(exitCode: 1, stdout: "", stderr: "boom")
            )

            let outcome = await runner.enableOrInstall(provider: .claudeCode, setup: Self.enabled)
            guard case .needsRepair(let message) = outcome.status else {
                Issue.record("expected needsRepair, got \(outcome.status)")
                return
            }
            #expect(message.contains("use Repair to reconcile"))
        }
    }

    @Test("Claude install confirmation discloses the conditional stale-install uninstall")
    func claudeConfirmationDisclosesConditionalUninstall() async throws {
        try await Self.withRunner { runner, _, _ in
            let confirmation = runner.confirmation(for: .repair, provider: .claudeCode, setup: Self.enabled)
            #expect(
                confirmation.commandLines.contains(
                    "claude plugin uninstall awesomux-claude-status@awesomux-claude --scope user (only when replacing a stale install)"
                )
            )
        }
    }

    @Test("Claude: a missing recorded binary falls back to the live binary for the clean reinstall")
    func claudeCleanReinstallDeadRecordedBinaryFallsBack() async throws {
        try await Self.withRunner { runner, command, _ in
            command.defaultOutcome = .result(.ok(stdout: ""))
            _ = await runner.enableOrInstall(
                provider: .claudeCode,
                setup: AgentIntegrationSetup(enabled: true, binaryPath: "/gone/claude")
            )
            try Self.rewriteInstallRecord(runner: runner, provider: .claudeCode) {
                $0.helperPath = Self.staleHelperPath
            }
            // The recorded binary vanished; the live default binary still works.
            command.stub(executable: "/gone/claude", failure: .executableNotFound("/gone/claude"))
            command.stub(args: ["plugin", "list", "--json"], result: .ok(stdout: Self.claudeList(enabled: true)))

            let before = command.invocations.count
            let outcome = await runner.enableOrInstall(provider: .claudeCode, setup: Self.enabled)
            #expect(outcome.status == .enabled)

            // The uninstall still ran — via the live binary, not the dead one.
            let invocations = Array(command.invocations.dropFirst(before))
            let uninstall = try #require(invocations.first { $0.args == Self.claudeUninstallArgvExpected })
            #expect(uninstall.executable == "claude")
        }
    }

    @Test("Claude: an uninstall failure names the step's executable, not the live one")
    func claudeCleanReinstallErrorNamesStepExecutable() async throws {
        try await Self.withRunner { runner, command, _ in
            command.defaultOutcome = .result(.ok(stdout: ""))
            _ = await runner.enableOrInstall(
                provider: .claudeCode,
                setup: AgentIntegrationSetup(enabled: true, binaryPath: "/recorded/claude")
            )
            try Self.rewriteInstallRecord(runner: runner, provider: .claudeCode) {
                $0.helperPath = Self.staleHelperPath
            }
            // The probe still answers (default outcome), but the uninstall step
            // itself cannot spawn the recorded binary.
            command.stub(
                executable: "/recorded/claude",
                args: Self.claudeUninstallArgvExpected,
                failure: .executableNotFound("/recorded/claude")
            )

            let outcome = await runner.enableOrInstall(provider: .claudeCode, setup: Self.enabled)
            guard case .unsupported(let message) = outcome.status else {
                Issue.record("expected unsupported, got \(outcome.status)")
                return
            }
            #expect(message.contains("/recorded/claude"))
        }
    }

    @Test("update-available gates like an installed-and-working state, with repair offered")
    func updateAvailableGating() {
        let status = AgentPluginStatus.updateAvailable("A newer awesoMux status plugin is available")
        #expect(status.label == "Update available")
        #expect(status.allowsRepair)
        #expect(status.allowsDisable)
        #expect(status.allowsUninstall)
        #expect(!status.allowsEnable)
    }

    // MARK: - Diagnostics

    @Test("a failed op produces redacted, capped diagnostics with exit code and args")
    func failedOpDiagnostics() async throws {
        try await Self.withRunner { runner, command, _ in
            let home = runner.homeDirectoryURL.path
            command.defaultOutcome = .result(
                CommandResult(exitCode: 7, stdout: "", stderr: "boom at \(home)/secret/path")
            )
            let outcome = await runner.enableOrInstall(provider: .claudeCode, setup: Self.enabled)

            let diagnostics = try #require(outcome.diagnostics)
            #expect(diagnostics.exitCode == 7)
            #expect(!diagnostics.args.isEmpty)
            // Runner home collapsed to ~ in the captured stderr.
            #expect(diagnostics.stderr.contains("~/secret/path"))
            #expect(!diagnostics.stderr.contains(home))
        }
    }

    @Test("redaction anchors on the home boundary and leaves sibling paths intact")
    func redactionAnchorsOnHomeBoundary() {
        let home = URL(fileURLWithPath: "/Users/example")
        // A path under home collapses; a sibling directory that merely shares the
        // prefix must not be mangled into `~2/...`.
        #expect(AgentPluginDiagnostics.redact("/Users/example/secret", homeDirectory: home) == "~/secret")
        #expect(AgentPluginDiagnostics.redact("/Users/example2/work", homeDirectory: home) == "/Users/example2/work")
        // A bare home token (e.g. a config-home arg) collapses to `~`.
        #expect(AgentPluginDiagnostics.redact("/Users/example", homeDirectory: home) == "~")
        #expect(AgentPluginDiagnostics.redact("home=/Users/example,", homeDirectory: home) == "home=~,")
        #expect(AgentPluginDiagnostics.redact("see /Users/example log", homeDirectory: home) == "see ~ log")
    }

    @Test("diagnostics cap long output with a truncation marker")
    func diagnosticsCapsOutput() {
        let long = String(repeating: "line\n", count: AgentPluginDiagnostics.maxLines + 50)
        let diagnostics = AgentPluginDiagnostics(
            executablePath: "/bin/x", args: [], exitCode: 1,
            rawStdout: long, rawStderr: "",
            summary: "x", homeDirectory: URL(fileURLWithPath: "/Users/nobody")
        )
        #expect(diagnostics.stdout.contains("[truncated]"))
        #expect(diagnostics.stdout.split(separator: "\n").count <= AgentPluginDiagnostics.maxLines + 2)
    }

    @Test("diagnostics keep long stderr tail")
    func diagnosticsKeepStderrTail() {
        let stderr = (0..<100).map { "line \($0)" }.joined(separator: "\n") + "\nfinal useful error"
        let diagnostics = AgentPluginDiagnostics(
            executablePath: "/bin/x", args: [], exitCode: 1,
            rawStdout: "", rawStderr: stderr,
            summary: "failed", homeDirectory: URL(fileURLWithPath: "/Users/nobody")
        )

        #expect(diagnostics.stderr.contains("[truncated]"))
        #expect(diagnostics.stderr.contains("final useful error"))
        #expect(!diagnostics.stderr.contains("line 0\nline 1\nline 2"))
        #expect(diagnostics.summary == "failed")
    }

    // MARK: - Fixtures

    static let enabled = AgentIntegrationSetup(enabled: true)

    static func claudeList(enabled: Bool, errors: [String] = [], installPath: String? = nil) -> String {
        let errorsJSON = errors.isEmpty ? "[]" : "[\(errors.map { "\"\($0)\"" }.joined(separator: ","))]"
        let installPathJSON = installPath.map { "\"\($0)\"" } ?? "null"
        return """
            [{"name":"awesomux-claude-status@awesomux-claude","enabled":\(enabled),"errors":\(errorsJSON),"installPath":\(installPathJSON)}]
            """
    }

    /// Deploys a Claude plugin cache copy at `installPath/hooks/hooks.json` with
    /// the given hook command baked in, mirroring what `claude plugin install`
    /// snapshots into `~/.claude/plugins/cache`.
    static func deployClaudePluginCopy(installPath: URL, command: String) throws {
        let hooksDir = installPath.appending(path: "hooks", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true)
        var template = try String(
            contentsOf:
                packageResourcesURL
                .appending(path: "AgentIntegrations/claude_code/plugins/awesomux-claude-status/hooks/hooks.json"),
            encoding: .utf8
        )
        template = template.replacingOccurrences(
            of: AgentPluginTemplateRenderer.helperPlaceholderToken,
            with: "AWESOMUX_AGENT_HOOK=${AWESOMUX_AGENT_HOOK:-'\(command)'};"
        )
        try Data(template.utf8).write(to: hooksDir.appending(path: "hooks.json"), options: .atomic)
    }

    static func grokList(
        status: String = "installed",
        path: String = "/Users/example/.grok/installed-plugins/awesomux-grok-status-test"
    ) -> String {
        """
        [{
          "status": "\(status)",
          "name": "awesomux-grok-status",
          "repo_key": "awesomux-grok-status-test",
          "version": "0.1.0",
          "path": "\(path)",
          "source": "/tmp/awesomux-grok-status",
          "marketplace": null
        }]
        """
    }

    /// Extracts the single-quoted helper path baked by `deployClaudePluginCopy`.
    static func bakedHelperPath(from renderedHooksJSON: Data) -> String {
        let text = String(decoding: renderedHooksJSON, as: UTF8.self)
        guard
            let range = text.range(of: "AWESOMUX_AGENT_HOOK:-'"),
            let end = text[range.upperBound...].firstIndex(of: "'")
        else {
            Issue.record("fixture render carries no baked helper path")
            return ""
        }
        return String(text[range.upperBound..<end])
    }

    /// A real executable file so deployed-copy checks see a live helper.
    static func makeExecutableHelper(in homeDirectory: URL) throws -> URL {
        let helper =
            homeDirectory
            .appending(path: "helpers-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "awesoMuxAgentHook")
        try FileManager.default.createDirectory(
            at: helper.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        return helper
    }

    /// Overwrites the recorded `sourceContentDigest` so status can be driven to
    /// Needs Repair without rewriting the bundled plugin tree under Resources.
    /// Pass `nil` to model a pre-fingerprint install record.
    static func rewriteInstallRecordDigest(
        runner: ProcessAgentPluginRunner,
        provider: AgentPluginProvider,
        digest: String?
    ) throws {
        try rewriteInstallRecord(runner: runner, provider: provider) {
            $0.sourceContentDigest = digest
        }
    }

    /// Rewrites the persisted install record on disk — the seam for modeling a
    /// record from a prior install (stale helper path, stale digest) that the
    /// fixed test resolver could never produce.
    static func rewriteInstallRecord(
        runner: ProcessAgentPluginRunner,
        provider: AgentPluginProvider,
        mutate: (inout AgentPluginInstallRecord) -> Void
    ) throws {
        let url = runner.pluginManifestURL
        var manifest = try JSONDecoder().decode(
            AgentPluginInstallManifest.self,
            from: Data(contentsOf: url)
        )
        guard let index = manifest.records.firstIndex(where: { $0.provider == provider }) else {
            Issue.record("missing install record for \(provider.rawValue)")
            return
        }
        mutate(&manifest.records[index])
        try JSONEncoder().encode(manifest).write(to: url, options: .atomic)
    }

    /// Writes a minimal Grok plugin tree with the given hook event keys so status
    /// can inspect on-disk hook freshness without shelling out to `grok`.
    /// Place the tree under `homeDirectory` (the runner's home) so GROK_HOME
    /// confinement accepts the path.
    static func writeGrokPluginHooks(
        eventNames: [String],
        homeDirectory: URL = FileManager.default.temporaryDirectory
    ) throws -> URL {
        let root =
            homeDirectory
            .appending(path: ".grok", directoryHint: .isDirectory)
            .appending(path: "installed-plugins", directoryHint: .isDirectory)
            .appending(path: "awesomux-grok-hooks-\(UUID().uuidString)", directoryHint: .isDirectory)
        let hooksDir = root.appending(path: "hooks", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true)

        var hooksObject: [String: Any] = [:]
        for name in eventNames {
            hooksObject[name] = [
                [
                    "hooks": [
                        [
                            "type": "command",
                            "command": "true",
                            "timeout": 10,
                        ]
                    ]
                ]
            ]
        }
        let data = try JSONSerialization.data(
            withJSONObject: ["hooks": hooksObject],
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: hooksDir.appending(path: "hooks.json"), options: .atomic)
        return root
    }

    static func codexHook(
        enabled: Bool,
        trust: HookTrustStatus,
        key: String = "/home/.codex/config.toml:pre_tool_use:0:0",
        pluginId: String? = "awesomux-codex-status@awesomux-codex",
        command: String? = nil
    ) -> HookEntry {
        HookEntry(
            key: key,
            eventName: "pre_tool_use",
            isManaged: false,
            pluginId: pluginId,
            command: command,
            enabled: enabled,
            currentHash: "sha256:abc",
            trustStatus: trust,
            sourcePath: "/home/.codex/config.toml",
            source: "plugin"
        )
    }

    /// Builds a runner whose renderer reads the real bundled marketplace trees
    /// (so refs derive from the actual marketplace.json) into a throwaway support
    /// dir, with a stub command runner and a stub Codex client.
    static func withRunner(
        _ body: (ProcessAgentPluginRunner, StubCommandRunner, StubCodexAppServerClient) async throws -> Void
    ) async throws {
        let support = FileManager.default.temporaryDirectory
            .appending(path: "awesomux-runner-\(UUID().uuidString)", directoryHint: .isDirectory)
        let home = support.appending(path: "home", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: support) }

        let command = StubCommandRunner()
        let codex = StubCodexAppServerClient()
        let runner = makeRunner(
            renderedSupport: support,
            command: command,
            codex: codex,
            homeDirectoryURL: home
        )
        try await body(runner, command, codex)
    }

    static func makeRunner(
        renderedSupport: URL,
        installState: URL? = nil,
        legacyInstallState: URL? = nil,
        command: StubCommandRunner = StubCommandRunner(),
        codex: StubCodexAppServerClient = StubCodexAppServerClient(),
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> ProcessAgentPluginRunner {
        let renderer = AgentPluginTemplateRenderer(
            resourcesDirectoryURL: packageResourcesURL,
            supportDirectoryURL: renderedSupport
        )
        return ProcessAgentPluginRunner(
            commandRunner: command,
            renderer: renderer,
            codexClientFactory: { _, _ in codex },
            homeDirectoryURL: homeDirectoryURL,
            helperPathResolver: {
                AgentHookHelperPath(path: "/Applications/awesoMux.app/Contents/MacOS/awesoMuxAgentHook", isDevelopmentBundle: false)
            },
            installStateDirectoryURL: installState,
            legacyInstallStateDirectoryURL: legacyInstallState
        )
    }

    static func startExternalLockHolder(in directory: URL) throws -> Process {
        let readyURL = directory.appending(path: "lock-ready")
        // Perl, not python3: /usr/bin/python3 resolves to Xcode's
        // Python.app bundle, which LaunchServices registers as a regular
        // foreground app — every run flashed an empty window on the desktop.
        // /usr/bin/perl is a plain executable and has flock built in.
        let script = """
            use strict;
            use warnings;
            use Fcntl qw(:flock);
            use File::Path qw(make_path);
            make_path($ARGV[0]);
            open(my $lock, ">>", "$ARGV[0]/.install-state.lock") or die $!;
            flock($lock, LOCK_EX) or die $!;
            open(my $ready, ">", $ARGV[1]) or die $!;
            close($ready);
            sleep 30;
            """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-e", script, directory.path, readyURL.path]
        try process.run()

        // 30s, matching the async sibling in AgentIntegrationInstallerTests. The
        // old 1s budget was measured at 0.802s under full-suite load, so it was
        // one scheduling stall away from flaking. This helper is synchronous, so
        // the async `waitUntilEventually` is not a drop-in.
        for _ in 0..<3000 where !FileManager.default.fileExists(atPath: readyURL.path) {
            Thread.sleep(forTimeInterval: 0.01)
        }
        try #require(FileManager.default.fileExists(atPath: readyURL.path))
        return process
    }

    static var packageResourcesURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Resources", directoryHint: .isDirectory)
    }
}

private extension CommandResult {
    static func ok(stdout: String) -> CommandResult {
        CommandResult(exitCode: 0, stdout: stdout, stderr: "")
    }
}
