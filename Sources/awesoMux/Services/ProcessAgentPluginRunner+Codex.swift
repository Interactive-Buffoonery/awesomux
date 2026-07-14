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
           !directoryExists(home) {
            return AgentPluginStatusReport(status: .needsRepair(codexMissingHomeGuidance(home: home)))
        }

        // `allow_managed_hooks_only` makes Codex ignore every user/project/session
        // hook — ours included — so the environment cannot host our hook at all
        // (contract §2.3/§2.5 → Unsupported). Check before probing: it short-
        // circuits a pointless app-server spawn, and a healthy-looking hook would
        // still never run under the policy.
        if codexManagedHooksOnly(home: home) {
            return AgentPluginStatusReport(status: .unsupported(
                "Codex is set to allow_managed_hooks_only; user hooks like awesoMux's are ignored in this environment"
            ))
        }

        guard let ref = effectiveRefForRecordedInstall(provider: .codex)
            ?? (try? marketplaceRef(provider: .codex)) else {
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

        return codexMapHooks(hooks, ref: ref, hasInstallRecord: installRecord(provider: .codex) != nil)
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
        return "Actions target the recorded home \(recordedHome); the CODEX_HOME field now points at \(liveHome). Repair to move the install, or restore the field to keep using the recorded home."
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
        hasInstallRecord: Bool
    ) -> AgentPluginStatusReport {
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
        if let guidance = outdatedSourceContentGuidance(provider: .codex) {
            return AgentPluginStatusReport(status: .needsRepair(guidance))
        }

        return AgentPluginStatusReport(status: .enabled)
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
           !directoryExists(home) {
            return AgentPluginActionOutcome(status: .needsRepair(codexMissingHomeGuidance(home: home)))
        }

        if codexManagedHooksOnly(home: home) {
            return AgentPluginActionOutcome(status: .unsupported(
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
        let steps: [MutationStep] = [
            MutationStep(["plugin", "marketplace", "add", tree.marketplaceRootURL.path]),
            MutationStep(["plugin", "add", ref.pluginRef])
        ]
        if let failure = await runMutationSteps(
            executable: executable,
            steps: steps,
            env: env,
            repairGuidance: "Install failed partway through; use Repair to reconcile",
            mapCommandError: { codexMutationFailure($0, executable: executable) }
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
        guard let ref = effectiveRefForRecordedInstall(provider: .codex)
            ?? (try? marketplaceRef(provider: .codex)) else {
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
        guard let ref = effectiveRefForRecordedInstall(provider: .codex)
            ?? (try? marketplaceRef(provider: .codex)) else {
            return AgentPluginActionOutcome(status: .unsupported("Bundled marketplace catalog is missing"))
        }
        let env = codexEnvironment(home: home)
        let steps: [MutationStep] = [
            MutationStep(["plugin", "remove", ref.pluginRef]),
            MutationStep(["plugin", "marketplace", "remove", ref.marketplaceName])
        ]
        if let failure = await runMutationSteps(
            executable: executable,
            steps: steps,
            env: env,
            repairGuidance: "Uninstall failed partway through; use Repair to reconcile",
            mapCommandError: { codexMutationFailure($0, executable: executable) }
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

    func codexCommandLines(_ action: AgentPluginAction, ref: AgentPluginMarketplaceRef, codexHome: String) -> [String] {
        switch action {
        case .enableOrInstall, .repair:
            [
                "CODEX_HOME=\(codexHome) codex plugin marketplace add [generated awesoMux marketplace path]",
                "CODEX_HOME=\(codexHome) codex plugin add \(ref.pluginRef)",
                "config/batchWrite hooks.state[<hook keys>] = { enabled: true } (upsert, reload)"
            ]
        case .disable:
            ["config/batchWrite hooks.state[<hook keys>] = { enabled: false } (upsert, reload)"]
        case .uninstall:
            [
                "CODEX_HOME=\(codexHome) codex plugin remove \(ref.pluginRef)",
                "CODEX_HOME=\(codexHome) codex plugin marketplace remove \(ref.marketplaceName)"
            ]
        }
    }

    // MARK: CODEX_HOME

    func codexHome(setup: AgentIntegrationSetup) -> URL {
        if let configHome = setup.configHome?.trimmingCharacters(in: .whitespacesAndNewlines), !configHome.isEmpty {
            return URL(fileURLWithPath: (configHome as NSString).expandingTildeInPath)
        }
        return homeDirectoryURL.appending(path: ".codex", directoryHint: .isDirectory)
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
            "PATH": mergedToolPath()
        ]
    }

    private func directoryExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return renderer.fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
