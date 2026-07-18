import AwesoMuxConfig
import Foundation

// MARK: - Claude Code path

extension ProcessAgentPluginRunner {
    // MARK: Status

    func claudeStatus(setup liveSetup: AgentIntegrationSetup) async -> AgentPluginStatusReport {
        var report = await claudeStatusReport(setup: liveSetup)
        // Like Codex: an edited-after-install Config home field can split where
        // status reads from and where actions write to, at any status, so the
        // drift note is attached uniformly rather than folded into one status.
        report.note = claudeConfigHomeDriftNote(live: liveSetup)
        return report
    }

    private func claudeStatusReport(setup liveSetup: AgentIntegrationSetup) async -> AgentPluginStatusReport {
        let setup = effectiveSetupForRecordedInstall(provider: .claudeCode, current: liveSetup)
        let executable = resolvedExecutable(provider: .claudeCode, setup: setup)
        let ref: AgentPluginMarketplaceRef
        if let recordedRef = effectiveRefForRecordedInstall(provider: .claudeCode) {
            ref = recordedRef
        } else if let renderedRef = try? marketplaceRef(provider: .claudeCode) {
            ref = renderedRef
        } else {
            return AgentPluginStatusReport(status: .unsupported("Bundled marketplace catalog is missing"))
        }

        let args = ["plugin", "list", "--json"]
        let result: CommandResult
        do {
            result = try await commandRunner.run(
                executable: executable,
                args: args,
                env: claudeEnvironment(setup: setup),
                cwd: nil
            )
        } catch let error as CommandRunnerError {
            return claudeProbeFailure(error, executable: executable, args: args)
        } catch {
            return AgentPluginStatusReport(status: .unsupported(error.localizedDescription))
        }

        guard result.isSuccess else {
            // A present binary that exits non-zero is an op failure (surface
            // stderr), but for a status read we degrade to repair guidance with
            // the diagnostics attached rather than blocking.
            return AgentPluginStatusReport(
                status: .needsRepair("claude plugin list failed; re-install may be required"),
                diagnostics: diagnostics(
                    executable: executable, args: args, result: result,
                    summary: "claude plugin list --json exited \(result.exitCode)"
                )
            )
        }

        return claudeMapList(result.stdout, ref: ref, executable: executable, args: args)
    }

    private func claudeProbeFailure(
        _ error: CommandRunnerError,
        executable: String,
        args: [String]
    ) -> AgentPluginStatusReport {
        switch error {
        case .executableNotFound:
            return AgentPluginStatusReport(status: .unsupported("The claude CLI was not found at \(executable)"))
        case .spawnFailed(_, let reason):
            return AgentPluginStatusReport(status: .unsupported("claude could not be started at \(executable): \(reason)"))
        case .timedOut:
            return AgentPluginStatusReport(status: .unsupported("claude plugin list timed out"))
        }
    }

    private func claudeMutationFailure(
        _ error: CommandRunnerError,
        executable: String
    ) -> AgentPluginStatus {
        switch error {
        case .executableNotFound:
            return .unsupported("The claude CLI was not found at \(executable)")
        case .spawnFailed(_, let reason):
            return .unsupported("claude could not be started at \(executable): \(reason)")
        case .timedOut:
            return .needsRepair("The claude command timed out; use Repair to retry")
        }
    }

    private func claudeMapList(
        _ stdout: String,
        ref: AgentPluginMarketplaceRef,
        executable: String,
        args: [String]
    ) -> AgentPluginStatusReport {
        let entries: [ClaudePluginListEntry]
        do {
            entries = try ClaudePluginList.parse(stdout)
        } catch {
            // No parseable JSON on stdout → `--json` unsupported on this version.
            return AgentPluginStatusReport(status: .unsupported("This claude version does not support plugin list --json"))
        }

        guard let entry = entries.first(where: { $0.matches(ref) }) else {
            return AgentPluginStatusReport(status: .notInstalled)
        }

        if !entry.errors.isEmpty {
            return AgentPluginStatusReport(
                status: .needsRepair("The plugin reported errors: \(entry.errors.joined(separator: "; "))")
            )
        }

        if !entry.enabled {
            return AgentPluginStatusReport(status: .disabled)
        }

        if let guidance = outdatedSourceContentGuidance(provider: .claudeCode) {
            return AgentPluginStatusReport(status: .needsRepair(guidance))
        }

        return AgentPluginStatusReport(status: .enabled)
    }

    // MARK: Enable / install

    func claudeEnableOrInstall(setup: AgentIntegrationSetup) async -> AgentPluginActionOutcome {
        let executable = resolvedExecutable(provider: .claudeCode, setup: setup)

        let tree: AgentPluginRenderedTree
        let ref: AgentPluginMarketplaceRef
        do {
            tree = try renderedTree(provider: .claudeCode, setup: setup)
            ref = try AgentPluginMarketplaceRef.read(fromRenderedTreeAt: tree.marketplaceRootURL, fileManager: renderer.fileManager)
        } catch AgentPluginRunnerError.helperPathUnavailable {
            return AgentPluginActionOutcome(status: .unsupported("The bundled status helper could not be resolved"))
        } catch {
            return AgentPluginActionOutcome(status: .needsRepair("Rendering the plugin tree failed: \(error.localizedDescription)"))
        }

        let root = tree.marketplaceRootURL.path
        let env = claudeEnvironment(setup: setup)

        // validate → [uninstall stale install] → marketplace add → install. Each
        // is a distinct argv (the confirmation sheet pre-named them); a failure
        // at any step surfaces that step's diagnostics verbatim. `validate` is
        // read-only; the uninstall, marketplace-add, and install steps mutate,
        // so only they arm the repairable-failure path.
        var steps: [MutationStep] = [
            MutationStep(["plugin", "validate", root], mutates: false)
        ]
        // `claude plugin install` keys its cache on the plugin manifest version,
        // which awesoMux never changes — reinstalling over an existing install
        // no-ops and keeps the previously baked hook config, including a dead
        // dev dist/ helper path (INT-651). A recorded install whose baked
        // content drifted must be uninstalled first so the install re-pulls the
        // fresh render. The uninstall targets the *recorded* install (its
        // executable, config home, and ref), and sits after the read-only
        // validate so a malformed render can never remove a working install.
        // Its failure aborts before install — recordInstall then never rewrites
        // the record, so the staleness gate re-fires on the next attempt
        // instead of being silenced by a "successful" no-op install.
        if let staleRecord = staleCachedInstallRecord(provider: .claudeCode, tree: tree) {
            let recordedSetup = effectiveSetupForRecordedInstall(provider: .claudeCode, current: setup)
            let recordedExecutable = resolvedExecutable(provider: .claudeCode, setup: recordedSetup)
            let recordedEnv = claudeEnvironment(setup: recordedSetup)
            if await claudePluginInstalled(
                ref: staleRecord.pluginRef,
                executable: recordedExecutable,
                env: recordedEnv
            ) {
                steps.append(
                    MutationStep(
                        ["plugin", "uninstall", staleRecord.pluginRef.pluginRef, "--scope", "user"],
                        executable: recordedExecutable,
                        env: recordedEnv
                    )
                )
            }
        }
        steps.append(MutationStep(["plugin", "marketplace", "add", root]))
        steps.append(MutationStep(["plugin", "install", ref.pluginRef, "--scope", "user"]))
        if let failure = await runMutationSteps(
            executable: executable,
            steps: steps,
            env: env,
            repairGuidance: "Install failed partway through; use Repair to reconcile",
            mapCommandError: { claudeMutationFailure($0, executable: executable) }
        ) {
            return failure
        }

        let recordWarning = recordInstallWarning(provider: .claudeCode, setup: setup, tree: tree, ref: ref)
        return AgentPluginActionOutcome(
            status: .enabled,
            guidance: [recordWarning, "Run /reload-plugins in an open Claude session, or restart it, to pick this up"]
                .compactMap { $0 }
                .joined(separator: "\n")
        )
    }

    // MARK: Disable

    func claudeDisable(setup: AgentIntegrationSetup) async -> AgentPluginActionOutcome {
        let setup = effectiveSetupForRecordedInstall(provider: .claudeCode, current: setup)
        let executable = resolvedExecutable(provider: .claudeCode, setup: setup)
        guard
            let ref = effectiveRefForRecordedInstall(provider: .claudeCode)
                ?? (try? marketplaceRef(provider: .claudeCode))
        else {
            return AgentPluginActionOutcome(status: .unsupported("Bundled marketplace catalog is missing"))
        }
        // `disable` takes no scope (contract §1.2).
        switch await runMutation(
            executable: executable,
            args: ["plugin", "disable", ref.pluginRef],
            env: claudeEnvironment(setup: setup),
            mapCommandError: { claudeMutationFailure($0, executable: executable) }
        ) {
        case .success:
            return AgentPluginActionOutcome(status: .disabled)
        case .failure(let outcome):
            return outcome
        }
    }

    // MARK: Uninstall

    func claudeUninstall(setup: AgentIntegrationSetup) async -> AgentPluginActionOutcome {
        let setup = effectiveSetupForRecordedInstall(provider: .claudeCode, current: setup)
        let executable = resolvedExecutable(provider: .claudeCode, setup: setup)
        guard
            let ref = effectiveRefForRecordedInstall(provider: .claudeCode)
                ?? (try? marketplaceRef(provider: .claudeCode))
        else {
            return AgentPluginActionOutcome(status: .unsupported("Bundled marketplace catalog is missing"))
        }
        let env = claudeEnvironment(setup: setup)

        // Full uninstall = uninstall plugin, then de-register marketplace
        // (contract §1.2). `marketplace remove` takes `--scope user`; `uninstall`
        // takes `--scope user`.
        let steps: [MutationStep] = [
            MutationStep(["plugin", "uninstall", ref.pluginRef, "--scope", "user"]),
            MutationStep(["plugin", "marketplace", "remove", ref.marketplaceName, "--scope", "user"]),
        ]
        if let failure = await runMutationSteps(
            executable: executable,
            steps: steps,
            env: env,
            repairGuidance: "Uninstall failed partway through; use Repair to reconcile",
            mapCommandError: { claudeMutationFailure($0, executable: executable) }
        ) {
            return failure
        }

        try? removeInstallRecord(provider: .claudeCode)
        return AgentPluginActionOutcome(status: .notInstalled)
    }

    // MARK: Confirmation copy

    func claudeConfirmationTitle(_ action: AgentPluginAction) -> String {
        switch action {
        case .enableOrInstall: "Install the Claude Code status plugin"
        case .repair: "Repair the Claude Code status plugin"
        case .disable: "Disable the Claude Code status plugin"
        case .uninstall: "Remove the Claude Code status plugin"
        }
    }

    func claudeCommandLines(_ action: AgentPluginAction, ref: AgentPluginMarketplaceRef) -> [String] {
        switch action {
        case .enableOrInstall, .repair:
            [
                "claude plugin validate [generated awesoMux marketplace path]",
                "claude plugin uninstall \(ref.pluginRef) --scope user (only when replacing a stale install)",
                "claude plugin marketplace add [generated awesoMux marketplace path]",
                "claude plugin install \(ref.pluginRef) --scope user",
            ]
        case .disable:
            ["claude plugin disable \(ref.pluginRef)"]
        case .uninstall:
            [
                "claude plugin uninstall \(ref.pluginRef) --scope user",
                "claude plugin marketplace remove \(ref.marketplaceName) --scope user",
            ]
        }
    }

    // MARK: Internals

    /// Read-only presence probe for the clean-reinstall path. An unreadable or
    /// unparseable list counts as installed: the staleness gate only fires with
    /// a recorded install, and requiring the uninstall to succeed is safer than
    /// skipping it and letting a stale cached copy survive a "successful"
    /// reinstall — the exact silent failure INT-651 exists to prevent. Only a
    /// definitive "not listed" (out-of-band manual uninstall) skips the step.
    private func claudePluginInstalled(
        ref: AgentPluginMarketplaceRef,
        executable: String,
        env: [String: String]
    ) async -> Bool {
        guard
            let result = try? await commandRunner.run(
                executable: executable,
                args: ["plugin", "list", "--json"],
                env: env,
                cwd: nil
            ),
            result.isSuccess,
            let entries = try? ClaudePluginList.parse(result.stdout)
        else {
            return true
        }
        return entries.contains { $0.matches(ref) }
    }

    /// A note when the live Config home field diverges from the home the recorded
    /// install actually targeted. Status/disable/uninstall follow the recorded
    /// home; enable/repair follow the live field — so a post-install field edit
    /// silently splits where status reads from and where actions land. Surfacing
    /// the split lets the user reconcile it deliberately. `nil` when there is no
    /// record or the two agree.
    private func claudeConfigHomeDriftNote(live liveSetup: AgentIntegrationSetup) -> String? {
        guard let record = installRecord(provider: .claudeCode) else { return nil }
        let recordedHome = record.configHome
        let liveHome = claudeConfigHome(setup: liveSetup).path
        guard recordedHome != liveHome else { return nil }
        return
            "Actions target the recorded config home \(recordedHome); the Config home field now points at \(liveHome). Repair to move the install, or restore the field to keep using the recorded home."
    }

    func claudeConfigHome(setup: AgentIntegrationSetup) -> URL {
        if let configHome = setup.configHome?.trimmingCharacters(in: .whitespacesAndNewlines), !configHome.isEmpty {
            return URL(fileURLWithPath: (configHome as NSString).expandingTildeInPath)
        }
        return homeDirectoryURL.appending(path: ".claude", directoryHint: .isDirectory)
    }

    /// Claude needs `claude` resolvable on `PATH` (contract §3), and honors
    /// `CLAUDE_CONFIG_DIR` for the user settings directory. Forward only those
    /// keys so a custom config home affects every CLI op without inheriting the
    /// rest of the process environment.
    private func claudeEnvironment(setup: AgentIntegrationSetup) -> [String: String] {
        var env: [String: String] = ["PATH": mergedToolPath()]
        env["CLAUDE_CONFIG_DIR"] = claudeConfigHome(setup: setup).path
        return env
    }
}

// MARK: - Claude plugin list parsing

/// One entry from `claude plugin list --json`. The shape carries at least a
/// name/ref, an enabled flag, and an `errors` array (contract §1.3). We tolerate
/// either a flat `name@marketplace` field or split name/marketplace fields.
struct ClaudePluginListEntry: Decodable, Equatable, Sendable {
    var name: String?
    var marketplace: String?
    var enabled: Bool
    var errors: [String]

    enum CodingKeys: String, CodingKey {
        case name
        case marketplace
        case enabled
        case errors
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        marketplace = try container.decodeIfPresent(String.self, forKey: .marketplace)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        errors = try container.decodeIfPresent([String].self, forKey: .errors) ?? []
    }

    init(name: String?, marketplace: String?, enabled: Bool, errors: [String]) {
        self.name = name
        self.marketplace = marketplace
        self.enabled = enabled
        self.errors = errors
    }

    /// Matches our plugin either by the `name@marketplace` ref or by the bare
    /// plugin name when the CLI reports name and marketplace separately.
    func matches(_ ref: AgentPluginMarketplaceRef) -> Bool {
        if let name {
            if name == ref.pluginRef { return true }
            if name == ref.pluginName {
                return marketplace == nil || marketplace == ref.marketplaceName
            }
        }
        return false
    }
}

enum ClaudePluginList {
    /// `claude plugin list --json` may emit either a top-level array of entries or
    /// an object whose `plugins` key holds them. Parse both; anything else throws.
    static func parse(_ stdout: String) throws -> [ClaudePluginListEntry] {
        let data = Data(stdout.utf8)
        let decoder = JSONDecoder()
        if let array = try? decoder.decode([ClaudePluginListEntry].self, from: data) {
            return array
        }
        let wrapped = try decoder.decode(Wrapper.self, from: data)
        return wrapped.plugins
    }

    private struct Wrapper: Decodable {
        let plugins: [ClaudePluginListEntry]
    }
}
