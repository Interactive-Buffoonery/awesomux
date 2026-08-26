import AwesoMuxConfig
import Foundation

// MARK: - Codex path

extension ProcessAgentPluginRunner {
    // MARK: Status

    func codexStatus(setup liveSetup: AgentIntegrationSetup) async -> AgentPluginStatusReport {
        var report = await codexStatusReport(setup: liveSetup)
        // The drift note rides alongside whatever status the probe resolved: an
        // edited-after-install CODEX_HOME field can split where status reads from
        // and where actions write to, at any status, so it is attached uniformly
        // rather than folded into one status' detail.
        if let driftNote = codexConfigHomeDriftNote(live: liveSetup) {
            report.note = driftNote
            report.hasConfigHomeDrift = true
        }
        return report
    }

    private func codexStatusReport(setup liveSetup: AgentIntegrationSetup) async -> AgentPluginStatusReport {
        let setup = effectiveSetupForRecordedInstall(provider: .codex, current: liveSetup)
        let executable = resolvedExecutable(provider: .codex, setup: setup)
        let home = codexHome(setup: setup)

        // A configured-but-missing home means nothing is installed there
        // (contract §2.1): map to repair, not an error. An unset home resolves to
        // ~/.codex, which we do not require to pre-exist. The guidance points at
        // the CODEX_HOME field, not Repair: Repair re-reads the same configured
        // home and re-hits this guard, so the escape is to fix the path, not retry.
        if let configured = setup.configHome?.trimmingCharacters(in: .whitespacesAndNewlines),
            !configured.isEmpty,
            !directoryExists(home)
        {
            return AgentPluginStatusReport(status: .needsRepair(codexMissingHomeGuidance(home: home)))
        }

        // `allow_managed_hooks_only` makes Codex ignore every user/project/session
        // hook — ours included — so the environment cannot host our hook at all
        // (contract §2.3/§2.5 → Unsupported). Check before probing: it short-
        // circuits a pointless app-server spawn, and a healthy-looking hook would
        // still never run under the policy.
        if codexManagedHooksOnly(home: home) {
            return AgentPluginStatusReport(
                status: .unsupported(
                    "Codex is set to allow_managed_hooks_only; user hooks like awesoMux's are ignored in this environment"
                ))
        }

        guard
            let ref = effectiveRefForRecordedInstall(provider: .codex)
                ?? (try? marketplaceRef(provider: .codex))
        else {
            return AgentPluginStatusReport(status: .unsupported("Bundled marketplace catalog is missing"))
        }

        let hooks: [HookEntry]
        do {
            let client = try codexClientFactory(executable, home.path)
            defer { client.close() }
            hooks = try await client.hooksList()
        } catch let error as CodexAppServerError {
            return codexProbeFailure(error)
        } catch {
            return AgentPluginStatusReport(status: .unsupported(error.localizedDescription))
        }

        return await codexMapHooks(
            hooks,
            ref: ref,
            hasInstallRecord: installRecord(provider: .codex) != nil,
            executable: executable,
            home: home
        )
    }

    /// Guidance for a configured-but-missing CODEX_HOME. It names the field, not
    /// Repair: Repair re-reads the same live home and re-hits the missing-home
    /// guard, so it no-ops and traps the user in a loop. Editing the CODEX_HOME
    /// field to an existing directory (or clearing it to fall back to ~/.codex) is
    /// the actual escape — Repair only works once the field points somewhere real.
    private func codexMissingHomeGuidance(home: URL) -> String {
        "CODEX_HOME does not exist: \(home.path). Point the CODEX_HOME field at an existing directory (or clear it for ~/.codex), then Repair"
    }

    /// A note when the live CODEX_HOME field diverges from the home the recorded
    /// install actually targeted. Status/disable/uninstall follow the recorded
    /// home; enable/repair follow the live field — so a post-install field edit
    /// silently splits where status reads from and where actions land. Surfacing
    /// the split lets the user reconcile it deliberately. `nil` when there is no
    /// record or the two agree.
    private func codexConfigHomeDriftNote(live liveSetup: AgentIntegrationSetup) -> String? {
        guard let record = installRecord(provider: .codex) else { return nil }
        let recordedHome = record.configHome
        let liveHome = codexHome(setup: liveSetup).path
        guard recordedHome != liveHome else { return nil }
        return
            "Actions target the recorded home \(recordedHome); the CODEX_HOME field now points at \(liveHome). Repair to move the install, or restore the field to keep using the recorded home."
    }

    /// Best-effort read of the documented `allow_managed_hooks_only` flag in the
    /// user-scope `requirements.toml` under CODEX_HOME (contract §2.3). A missing
    /// file means the policy is off; project/session-scoped requirements are out
    /// of reach here. A naive line scan, not a TOML parse — one boolean flag does
    /// not justify a parser dependency.
    func codexManagedHooksOnly(home: URL) -> Bool {
        let url = home.appending(path: "requirements.toml")
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return false
        }
        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let withoutComment = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            let trimmed = withoutComment.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("allow_managed_hooks_only") else { continue }
            let value = trimmed.drop(while: { $0 != "=" }).dropFirst().trimmingCharacters(in: .whitespaces)
            if value == "true" {
                return true
            }
        }
        return false
    }

    private func codexProbeFailure(_ error: CodexAppServerError) -> AgentPluginStatusReport {
        switch error {
        case .appServerUnavailable(let reason):
            return AgentPluginStatusReport(status: .unsupported("The codex app-server is unavailable: \(reason)"))
        case .methodNotFound(let method):
            return AgentPluginStatusReport(status: .unsupported("This codex version does not support \(method)"))
        case .rpcError(_, let message):
            return AgentPluginStatusReport(status: .needsRepair("codex hooks/list errored: \(message)"))
        case .connectionClosed, .requestTimedOut, .malformedResponse:
            return AgentPluginStatusReport(status: .unsupported("The codex app-server did not respond"))
        }
    }

    private func codexMapHooks(
        _ hooks: [HookEntry],
        ref: AgentPluginMarketplaceRef,
        hasInstallRecord: Bool,
        executable: String,
        home: URL
    ) async -> AgentPluginStatusReport {
        let matchingHooks = hooks.filter { codexHookMatches($0, ref: ref) }
        guard !matchingHooks.isEmpty else {
            // With a recorded install but no matching hook, the install drifted or
            // was removed out-of-band: repair (or remove) it rather than report
            // not-installed, which hides Remove and traps the user on Install-only
            // (contract §2.5: pluginId configured but no matching hook → Needs
            // repair). Without a record, nothing was ever installed here.
            return AgentPluginStatusReport(
                status: hasInstallRecord
                    ? .needsRepair("awesoMux's Codex hook was installed but Codex reports no matching hook; repair or remove it")
                    : .notInstalled
            )
        }

        if matchingHooks.allSatisfy({ !$0.enabled }) {
            // User disabled it; respect that (contract §2.5). Offer enable, never
            // auto-flip.
            return AgentPluginStatusReport(status: .disabled)
        }

        // Deliberate priority: a partially-disabled install outranks an untrusted
        // one. A disabled hook cannot run at all regardless of trust, so the
        // fundamental fix is Repair (re-enable), which must precede the Approve
        // that an untrusted-but-enabled hook would ask for. Order matters: this
        // disabled check sits before the trust checks below so a hook set that is
        // both partially disabled *and* untrusted reports needsRepair, not
        // needsReview.
        if matchingHooks.contains(where: { !$0.enabled }) {
            return AgentPluginStatusReport(status: .needsRepair("Some awesoMux Codex hooks are disabled or missing"))
        }

        if matchingHooks.contains(where: { $0.trustStatus == .untrusted }) {
            return AgentPluginStatusReport(status: .needsReview("Approve the awesoMux hook in Codex to let it run"))
        }

        if matchingHooks.contains(where: { $0.trustStatus == .modified }) {
            // Decision 5: treat `modified` as needs-review in v1; hash-comparison
            // repair (user edit vs. our render drift) is a follow-up.
            return AgentPluginStatusReport(status: .needsReview("The hook changed since it was approved; re-approve it in Codex"))
        }

        if let unknown = matchingHooks.compactMap({ hook -> String? in
            guard case .unknown(let value) = hook.trustStatus else { return nil }
            return value
        }).first {
            return AgentPluginStatusReport(
                status: .needsReview(
                    "Codex reported an unfamiliar hook trust state (\(unknown)); review the hook in Codex"
                ))
        }

        // Bundled source moved under the user (app update) outranks "enabled":
        // Repair reinstalls the new hooks; Codex will then re-ask for trust.
        // Before offering that update, check the registered plugin directory's
        // deployed hooks: trust hashes are content-keyed, so Codex reports a
        // hook fully healthy even when its baked helper path points at a build
        // folder that no longer exists (INT-882). That dead-helper state is a
        // repair, not an update.
        if let deadHelperGuidance = await codexRegisteredDeadHelperGuidance(
            executable: executable,
            home: home,
            ref: ref
        ) {
            return AgentPluginStatusReport(status: .needsRepair(deadHelperGuidance))
        }

        if let guidance = outdatedSourceContentGuidance(provider: .codex) {
            return AgentPluginStatusReport(status: .updateAvailable(guidance))
        }

        return AgentPluginStatusReport(status: .enabled)
    }

    /// Reads the plugin directory Codex registered for our ref via
    /// `codex plugin list --json` and checks whether its deployed hook config
    /// can still reach the awesoMuxAgentHook helper. Returns repair guidance
    /// when the helper is determinably unreachable, and `nil` whenever the
    /// check cannot be performed (no entry, unreadable list, unreadable file) —
    /// an unverifiable deploy must never flip a healthy install to repair.
    private func codexRegisteredDeadHelperGuidance(
        executable: String,
        home: URL,
        ref: AgentPluginMarketplaceRef
    ) async -> String? {
        let args = ["plugin", "list", "--json"]
        guard
            let result = try? await commandRunner.run(
                executable: executable,
                args: args,
                env: codexEnvironment(home: home),
                cwd: nil
            ),
            result.isSuccess,
            let plugins = try? CodexPluginList.parse(result.stdout),
            let entry = plugins.first(where: { $0.matches(ref) }),
            let sourcePath = entry.sourcePath,
            !sourcePath.isEmpty
        else {
            return nil
        }
        let deployedHooksURL = URL(fileURLWithPath: sourcePath)
            .appending(path: "hooks", directoryHint: .isDirectory)
            .appending(path: "hooks.json")
        // A ladder-baked command self-heals through Spotlight, so only a copy
        // whose ladder provably cannot resolve (or whose baked path is gone
        // with no resolvable fallback) can strand on a dead helper.
        guard
            let finding = AgentPluginDeployedCopyInspector.helperReachability(
                deployedHooksURL: deployedHooksURL,
                fileManager: renderer.fileManager,
                ladderProbe: ladderProbe
            ),
            !finding.helperReachable
        else {
            return nil
        }
        let deadPath = finding.firstBakedHelperPath ?? "a missing helper"
        return
            "The registered status hook's command points at \(deadPath), which no longer exists; Repair to reinstall it from this copy of awesoMux"
    }

    /// Record-less replacement gate for the clean-reinstall flow (INT-882):
    /// with no install record there is no staleness bookkeeping, so inspect the
    /// plugin directory Codex registers for our fresh ref. A copy whose
    /// deployed hooks drifted from this render — or whose helper can no longer
    /// be resolved — would survive a version-keyed re-add unchanged, so Repair
    /// must remove it first. Unprovable states (unreadable list, unreadable or
    /// missing deployed hooks) leave the copy alone, matching the fail-open
    /// direction of every other deployed-copy check.
    private func codexRegisteredCopyNeedsReplacement(
        ref: AgentPluginMarketplaceRef,
        executable: String,
        env: [String: String],
        renderedHooksURL: URL?
    ) async -> Bool {
        guard let renderedHooksURL else {
            return false
        }
        let args = ["plugin", "list", "--json"]
        guard
            let result = try? await commandRunner.run(
                executable: executable,
                args: args,
                env: env,
                cwd: nil
            ),
            result.isSuccess,
            let plugins = try? CodexPluginList.parse(result.stdout),
            let entry = plugins.first(where: { $0.matches(ref) }),
            let sourcePath = entry.sourcePath,
            !sourcePath.isEmpty
        else {
            return false
        }
        guard
            let finding = AgentPluginDeployedCopyInspector.deployedCopyFinding(
                installPath: sourcePath,
                renderedHooksURL: renderedHooksURL,
                fileManager: renderer.fileManager,
                ladderProbe: ladderProbe
            )
        else {
            return false
        }
        return finding.differsFromCurrentRender || !finding.helperReachable
    }

    /// Matches by `pluginId == <plugin>@<marketplace>` first (decision 6), by the
    /// bare plugin name for older builds, then by the command only when
    /// `pluginId` is absent.
    func codexHookMatches(_ hook: HookEntry, ref: AgentPluginMarketplaceRef) -> Bool {
        if hook.pluginId == ref.pluginRef {
            return true
        }
        if let pluginId = hook.pluginId, pluginId == ref.pluginName {
            return true
        }
        guard hook.pluginId == nil, let command = hook.command else {
            return false
        }
        return command.contains(AgentRuntimeEnvironment.hookExecutableName)
            && command.contains("--provider codex")
    }

    // MARK: Enable / install

    func codexEnableOrInstall(setup: AgentIntegrationSetup) async -> AgentPluginActionOutcome {
        let executable = resolvedExecutable(provider: .codex, setup: setup)
        let home = codexHome(setup: setup)

        if let configured = setup.configHome?.trimmingCharacters(in: .whitespacesAndNewlines),
            !configured.isEmpty,
            !directoryExists(home)
        {
            return AgentPluginActionOutcome(status: .needsRepair(codexMissingHomeGuidance(home: home)))
        }

        if codexManagedHooksOnly(home: home) {
            return AgentPluginActionOutcome(
                status: .unsupported(
                    "Codex is set to allow_managed_hooks_only; user hooks like awesoMux's are ignored in this environment"
                ))
        }

        let tree: AgentPluginRenderedTree
        let ref: AgentPluginMarketplaceRef
        do {
            tree = try renderedTree(provider: .codex, setup: setup)
            ref = try AgentPluginMarketplaceRef.read(fromRenderedTreeAt: tree.marketplaceRootURL, fileManager: renderer.fileManager)
        } catch AgentPluginRunnerError.helperPathUnavailable {
            return AgentPluginActionOutcome(status: .unsupported("The bundled status helper could not be resolved"))
        } catch {
            return AgentPluginActionOutcome(status: .needsRepair("Rendering the plugin tree failed: \(error.localizedDescription)"))
        }

        let env = codexEnvironment(home: home)
        var steps: [MutationStep] = []
        // `codex plugin add` keeps a same-version cached plugin intact. When the
        // rendered helper path or bundled source has drifted, remove the recorded
        // plugin first so Repair actually picks up the freshly rendered hooks.
        // Target the recorded install's home; the following add steps target the
        // current settings, which is how Repair deliberately moves an install.
        if let staleRecord = staleCachedInstallRecord(provider: .codex, tree: tree) {
            let recordedSetup = effectiveSetupForRecordedInstall(provider: .codex, current: setup)
            var recordedExecutable = resolvedExecutable(provider: .codex, setup: recordedSetup)
            let recordedHome = codexHome(setup: recordedSetup)
            let recordedEnv = codexEnvironment(home: recordedHome)
            var installed: Bool
            do {
                installed = try await codexPluginInstalled(
                    ref: staleRecord.pluginRef,
                    executable: recordedExecutable,
                    env: recordedEnv
                )
            } catch {
                // The recorded binary can disappear after a user updates a
                // custom Codex path. Retry with the live executable, still
                // targeting the recorded home where the stale cache resides.
                recordedExecutable = executable
                installed =
                    (try? await codexPluginInstalled(
                        ref: staleRecord.pluginRef,
                        executable: executable,
                        env: recordedEnv
                    )) ?? true
            }
            if installed {
                steps.append(
                    MutationStep(
                        ["plugin", "remove", staleRecord.pluginRef.pluginRef],
                        executable: recordedExecutable,
                        env: recordedEnv
                    ))
            }
        } else if await codexRegisteredCopyNeedsReplacement(
            ref: ref,
            executable: executable,
            env: env,
            renderedHooksURL: tree.hookConfigURLs.first
        ) {
            // Deployed drift with no install record (out-of-band or
            // lost-manifest install). Without a removal the version-keyed add
            // would keep the stale copy in place forever — Repair must never be
            // a dead button (INT-882), so remove by our ref against the live
            // settings, mirroring the Claude record-less uninstall.
            steps.append(MutationStep(["plugin", "remove", ref.pluginRef]))
        }
        steps.append(MutationStep(["plugin", "marketplace", "add", tree.marketplaceRootURL.path]))
        steps.append(MutationStep(["plugin", "add", ref.pluginRef]))
        if let failure = await runMutationSteps(
            executable: executable,
            steps: steps,
            env: env,
            repairGuidance: "Install failed partway through; use Repair to reconcile",
            mapCommandError: { codexMutationFailure($0, executable: $1) }
        ) {
            return failure
        }

        let recordWarning = recordInstallWarning(provider: .codex, setup: setup, tree: tree, ref: ref)

        // After install, set the hook enabled-state via config/batchWrite, keyed
        // on the exact `hooks/list` key (Context7 correction). Discover the key,
        // then upsert.
        switch await codexSetEnabled(true, executable: executable, home: home, ref: ref) {
        case .success:
            return AgentPluginActionOutcome(
                status: .needsReview("Approve the awesoMux hook in Codex, then start a new thread to pick it up"),
                guidance: [recordWarning, "Codex requires approving the hook and starting a fresh thread"]
                    .compactMap { $0 }
                    .joined(separator: "\n")
            )
        case .failure(let outcome):
            return AgentPluginActionOutcome(
                status: .needsRepair(outcome.status.detail),
                guidance: outcome.guidance,
                diagnostics: outcome.diagnostics
            )
        }
    }

    // MARK: Disable

    func codexDisable(setup: AgentIntegrationSetup) async -> AgentPluginActionOutcome {
        let setup = effectiveSetupForRecordedInstall(provider: .codex, current: setup)
        let executable = resolvedExecutable(provider: .codex, setup: setup)
        let home = codexHome(setup: setup)
        guard
            let ref = effectiveRefForRecordedInstall(provider: .codex)
                ?? (try? marketplaceRef(provider: .codex))
        else {
            return AgentPluginActionOutcome(status: .unsupported("Bundled marketplace catalog is missing"))
        }
        switch await codexSetEnabled(false, executable: executable, home: home, ref: ref) {
        case .success:
            return AgentPluginActionOutcome(status: .disabled)
        case .failure(let outcome):
            return outcome
        }
    }

    // MARK: Uninstall

    func codexUninstall(setup: AgentIntegrationSetup) async -> AgentPluginActionOutcome {
        let setup = effectiveSetupForRecordedInstall(provider: .codex, current: setup)
        let executable = resolvedExecutable(provider: .codex, setup: setup)
        let home = codexHome(setup: setup)
        guard
            let ref = effectiveRefForRecordedInstall(provider: .codex)
                ?? (try? marketplaceRef(provider: .codex))
        else {
            return AgentPluginActionOutcome(status: .unsupported("Bundled marketplace catalog is missing"))
        }
        let env = codexEnvironment(home: home)
        let steps: [MutationStep] = [
            MutationStep(["plugin", "remove", ref.pluginRef]),
            MutationStep(["plugin", "marketplace", "remove", ref.marketplaceName]),
        ]
        if let failure = await runMutationSteps(
            executable: executable,
            steps: steps,
            env: env,
            repairGuidance: "Uninstall failed partway through; use Repair to reconcile",
            mapCommandError: { codexMutationFailure($0, executable: $1) }
        ) {
            return failure
        }
        try? removeInstallRecord(provider: .codex)
        return AgentPluginActionOutcome(status: .notInstalled)
    }

    // MARK: Confirmation copy

    func codexConfirmationTitle(_ action: AgentPluginAction) -> String {
        switch action {
        case .enableOrInstall: "Install the Codex status plugin"
        case .repair: "Repair the Codex status plugin"
        case .disable: "Disable the Codex status plugin"
        case .uninstall: "Remove the Codex status plugin"
        }
    }

    func codexCommandLines(
        _ action: AgentPluginAction,
        ref: AgentPluginMarketplaceRef,
        codexHome: String,
        staleRecord: AgentPluginInstallRecord? = nil,
        staleExecutable: String? = nil,
        fallbackExecutable: String? = nil
    ) -> [String] {
        switch action {
        case .enableOrInstall, .repair:
            var commands = [
                "CODEX_HOME=\(codexHome) codex plugin marketplace add [generated awesoMux marketplace path]",
                "CODEX_HOME=\(codexHome) codex plugin add \(ref.pluginRef)",
                "config/batchWrite hooks.state[<hook keys>] = { enabled: true } (upsert, reload)",
            ]
            if let staleRecord {
                let recordedExecutable = staleExecutable ?? "codex"
                var removal =
                    "CODEX_HOME=\(staleRecord.configHome) \(recordedExecutable) plugin remove \(staleRecord.pluginRef.pluginRef)"
                if let fallbackExecutable, fallbackExecutable != recordedExecutable {
                    removal += " (falls back to \(fallbackExecutable) if the recorded executable is unavailable)"
                }
                removal += " (only when replacing a stale install)"
                commands.insert(
                    removal,
                    at: 0
                )
            }
            return commands
        case .disable:
            return ["config/batchWrite hooks.state[<hook keys>] = { enabled: false } (upsert, reload)"]
        case .uninstall:
            return [
                "CODEX_HOME=\(codexHome) codex plugin remove \(ref.pluginRef)",
                "CODEX_HOME=\(codexHome) codex plugin marketplace remove \(ref.marketplaceName)",
            ]
        }
    }

    // MARK: CODEX_HOME

    func codexHome(setup: AgentIntegrationSetup) -> URL {
        AgentConfigHome.url(
            setup: setup,
            defaultDirectoryName: ".codex",
            homeDirectoryURL: homeDirectoryURL
        )
    }

    // MARK: Internals

    /// Maps a Codex CLI error to a status. Codex treats a timeout as Unsupported
    /// (the app-server / CLI is effectively unavailable), unlike Claude, which
    /// routes timeout to needsRepair.
    private func codexMutationFailure(
        _ error: CommandRunnerError,
        executable: String
    ) -> AgentPluginStatus {
        switch error {
        case .executableNotFound:
            return .unsupported("The codex CLI was not found at \(executable)")
        case .spawnFailed(_, let reason):
            return .unsupported("codex could not be started at \(executable): \(reason)")
        case .timedOut:
            return .unsupported("codex timed out")
        }
    }

    /// Read-only presence probe for a stale-cache replacement. An unreadable or
    /// unparseable list counts as installed: skipping cleanup in that state could
    /// preserve the stale same-version cache. A definitive empty `installed`
    /// array means an out-of-band removal already cleaned it up.
    private func codexPluginInstalled(
        ref: AgentPluginMarketplaceRef,
        executable: String,
        env: [String: String]
    ) async throws -> Bool {
        let result: CommandResult
        do {
            result = try await commandRunner.run(
                executable: executable,
                args: ["plugin", "list", "--json"],
                env: env,
                cwd: nil
            )
        } catch CommandRunnerError.executableNotFound(let path) {
            throw CommandRunnerError.executableNotFound(path)
        } catch {
            return true
        }
        guard result.isSuccess, let plugins = try? CodexPluginList.parse(result.stdout) else {
            return true
        }
        return plugins.contains { $0.matches(ref) }
    }

    /// Sets the awesoMux hook's enabled-state by discovering its exact
    /// `hooks/list` key, then upserting `hooks.state[<key>] = {enabled}` via
    /// `config/batchWrite` (Context7 correction: key from the wire, never
    /// reconstructed). One app-server session for read + write, closed via defer.
    private func codexSetEnabled(
        _ enabled: Bool,
        executable: String,
        home: URL,
        ref: AgentPluginMarketplaceRef
    ) async -> MutationResult {
        do {
            let client = try codexClientFactory(executable, home.path)
            defer { client.close() }

            let hooks = try await client.hooksList()
            let matchingHooks = hooks.filter { codexHookMatches($0, ref: ref) }
            guard !matchingHooks.isEmpty else {
                return .failure(AgentPluginActionOutcome(status: .needsRepair("No matching awesoMux hooks were found to update")))
            }

            let hookState = matchingHooks.reduce(into: [String: JSONValue]()) { result, hook in
                result[hook.key] = .object(["enabled": .bool(enabled)])
            }
            let write = CodexConfigWrite(
                keyPath: "hooks.state",
                value: .object(hookState),
                mergeStrategy: .upsert
            )
            try await client.configBatchWrite([write], reloadUserConfig: true)
            return .success
        } catch let error as CodexAppServerError {
            return .failure(AgentPluginActionOutcome(status: codexProbeFailure(error).status))
        } catch {
            return .failure(AgentPluginActionOutcome(status: .unsupported(error.localizedDescription)))
        }
    }

    private func codexEnvironment(home: URL) -> [String: String] {
        [
            "CODEX_HOME": home.path,
            "PATH": mergedToolPath(),
        ]
    }

    private func directoryExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return renderer.fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

// MARK: - Codex plugin list parsing

enum CodexPluginList {
    static func parse(_ stdout: String) throws -> [Entry] {
        try JSONDecoder().decode(Response.self, from: Data(stdout.utf8)).installed
    }

    struct Response: Decodable {
        var installed: [Entry]
    }

    struct Entry: Decodable {
        var pluginId: String?
        var name: String?
        var marketplaceName: String?
        /// The local directory Codex registered the plugin from
        /// (`source.path`). Our installs register awesoMux's rendered tree, so
        /// this names where the deployed hook config lives.
        var sourcePath: String?

        private enum CodingKeys: String, CodingKey {
            case pluginId
            case name
            case marketplaceName
            case source
        }

        private struct Source: Decodable {
            var path: String?
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            pluginId = try container.decodeIfPresent(String.self, forKey: .pluginId)
            name = try container.decodeIfPresent(String.self, forKey: .name)
            marketplaceName = try container.decodeIfPresent(String.self, forKey: .marketplaceName)
            // CLI builds vary in whether `source` is an object ({path}) or a
            // plain string path. A shape mismatch must not throw the whole
            // list parse away — the presence probe and dead-helper check both
            // degrade silently if installed entries vanish from our view.
            let objectShape = (try? container.decodeIfPresent(Source.self, forKey: .source)).flatMap { $0 }
            let stringShape = (try? container.decodeIfPresent(String.self, forKey: .source)).flatMap { $0 }
            sourcePath = objectShape?.path ?? stringShape
        }

        func matches(_ ref: AgentPluginMarketplaceRef) -> Bool {
            pluginId == ref.pluginRef
                || (name == ref.pluginName && marketplaceName == ref.marketplaceName)
        }
    }
}
