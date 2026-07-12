import AwesoMuxConfig
import Foundation

// MARK: - Grok path

extension ProcessAgentPluginRunner {
    // MARK: Status

    func grokStatus(setup liveSetup: AgentIntegrationSetup) async -> AgentPluginStatusReport {
        var report = await grokStatusReport(setup: liveSetup)
        if let driftNote = grokConfigHomeDriftNote(live: liveSetup) {
            report.note = driftNote
            report.hasConfigHomeDrift = true
        }
        return report
    }

    private func grokStatusReport(setup liveSetup: AgentIntegrationSetup) async -> AgentPluginStatusReport {
        let setup = effectiveSetupForRecordedInstall(provider: .grok, current: liveSetup)
        let executable = resolvedExecutable(provider: .grok, setup: setup)
        let home = grokHome(setup: setup)

        if let configured = setup.configHome?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty,
           !grokDirectoryExists(home) {
            return AgentPluginStatusReport(status: .needsRepair(grokMissingHomeGuidance(home: home)))
        }

        guard let ref = effectiveRefForRecordedInstall(provider: .grok)
            ?? (try? marketplaceRef(provider: .grok)) else {
            return AgentPluginStatusReport(status: .unsupported("Bundled Grok plugin manifest is missing"))
        }

        let args = ["plugin", "list", "--json"]
        let result: CommandResult
        do {
            result = try await commandRunner.run(
                executable: executable,
                args: args,
                env: grokEnvironment(home: home),
                cwd: nil
            )
        } catch let error as CommandRunnerError {
            return grokProbeFailure(error, executable: executable)
        } catch {
            return AgentPluginStatusReport(status: .unsupported(error.localizedDescription))
        }

        guard result.isSuccess else {
            return AgentPluginStatusReport(
                status: .needsRepair("grok plugin list failed; re-install may be required"),
                diagnostics: diagnostics(
                    executable: executable, args: args, result: result,
                    summary: "grok plugin list --json exited \(result.exitCode)"
                )
            )
        }

        return grokMapList(
            result.stdout,
            ref: ref,
            hasInstallRecord: installRecord(provider: .grok) != nil,
            allowedHome: home
        )
    }

    private func grokProbeFailure(
        _ error: CommandRunnerError,
        executable: String
    ) -> AgentPluginStatusReport {
        switch error {
        case .executableNotFound:
            return AgentPluginStatusReport(status: .unsupported("The grok CLI was not found at \(executable)"))
        case .spawnFailed(_, let reason):
            return AgentPluginStatusReport(status: .unsupported("grok could not be started at \(executable): \(reason)"))
        case .timedOut:
            return AgentPluginStatusReport(status: .unsupported("grok plugin list timed out"))
        }
    }

    private func grokMutationFailure(
        _ error: CommandRunnerError,
        executable: String
    ) -> AgentPluginStatus {
        switch error {
        case .executableNotFound:
            return .unsupported("The grok CLI was not found at \(executable)")
        case .spawnFailed(_, let reason):
            return .unsupported("grok could not be started at \(executable): \(reason)")
        case .timedOut:
            return .unsupported("grok timed out")
        }
    }

    private func grokMapList(
        _ stdout: String,
        ref: AgentPluginMarketplaceRef,
        hasInstallRecord: Bool,
        allowedHome: URL
    ) -> AgentPluginStatusReport {
        let entries: [GrokPluginListEntry]
        do {
            entries = try GrokPluginList.parse(stdout)
        } catch {
            return AgentPluginStatusReport(status: .unsupported("This grok version does not support plugin list --json"))
        }

        guard let entry = entries.first(where: { $0.matches(ref) }) else {
            return AgentPluginStatusReport(
                status: hasInstallRecord
                    ? .needsRepair("awesoMux's Grok plugin was installed but Grok reports no matching plugin; repair or remove it")
                    : .notInstalled
            )
        }

        switch entry.status?.lowercased() {
        case "disabled":
            return AgentPluginStatusReport(status: .disabled)
        case "error", "errored", "failed", "invalid":
            return AgentPluginStatusReport(status: .needsRepair("The Grok plugin reported status \(entry.status ?? "unknown")"))
        default:
            // Prefer the shared install-record digest (works for every provider
            // after an app update). Fall back to inspecting on-disk hooks for
            // legacy installs that predate the fingerprint, or installs with no
            // record — those still silently break when hooks stay on snake_case.
            if let guidance = outdatedSourceContentGuidance(provider: .grok) {
                return AgentPluginStatusReport(status: .needsRepair(guidance))
            }
            if let guidance = GrokInstalledHooksInspector.repairGuidanceIfStale(
                pluginDirectoryPath: entry.path,
                allowedHome: allowedHome,
                fileManager: renderer.fileManager
            ) {
                return AgentPluginStatusReport(status: .needsRepair(guidance))
            }
            return AgentPluginStatusReport(status: .enabled)
        }
    }

    // MARK: Enable / install

    func grokEnableOrInstall(setup: AgentIntegrationSetup) async -> AgentPluginActionOutcome {
        let executable = resolvedExecutable(provider: .grok, setup: setup)
        let home = grokHome(setup: setup)

        if let configured = setup.configHome?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty,
           !grokDirectoryExists(home) {
            return AgentPluginActionOutcome(status: .needsRepair(grokMissingHomeGuidance(home: home)))
        }

        let tree: AgentPluginRenderedTree
        let ref: AgentPluginMarketplaceRef
        do {
            tree = try renderedTree(provider: .grok, setup: setup)
            ref = try AgentPluginMarketplaceRef.read(fromRenderedTreeAt: tree.marketplaceRootURL, fileManager: renderer.fileManager)
        } catch AgentPluginRunnerError.helperPathUnavailable {
            return AgentPluginActionOutcome(status: .unsupported("The bundled status helper could not be resolved"))
        } catch {
            return AgentPluginActionOutcome(status: .needsRepair("Rendering the Grok plugin failed: \(error.localizedDescription)"))
        }

        let pluginDirectory = grokPluginDirectory(tree: tree, ref: ref)
        let env = grokEnvironment(home: home)
        let steps: [MutationStep] = [
            MutationStep(["plugin", "validate", pluginDirectory.path], mutates: false),
            MutationStep(["plugin", "install", pluginDirectory.path, "--trust"])
        ]
        if let failure = await runMutationSteps(
            executable: executable,
            steps: steps,
            env: env,
            repairGuidance: "Install failed partway through; use Repair to reconcile",
            mapCommandError: { grokMutationFailure($0, executable: executable) }
        ) {
            return failure
        }

        let recordWarning = recordInstallWarning(provider: .grok, setup: setup, tree: tree, ref: ref)
        return AgentPluginActionOutcome(
            status: .enabled,
            guidance: [recordWarning, "Restart open Grok sessions to pick this up"]
                .compactMap { $0 }
                .joined(separator: "\n")
        )
    }

    // MARK: Disable

    func grokDisable(setup: AgentIntegrationSetup) async -> AgentPluginActionOutcome {
        let setup = effectiveSetupForRecordedInstall(provider: .grok, current: setup)
        let executable = resolvedExecutable(provider: .grok, setup: setup)
        let home = grokHome(setup: setup)
        guard let ref = effectiveRefForRecordedInstall(provider: .grok)
            ?? (try? marketplaceRef(provider: .grok)) else {
            return AgentPluginActionOutcome(status: .unsupported("Bundled Grok plugin manifest is missing"))
        }

        switch await runMutation(
            executable: executable,
            args: ["plugin", "disable", ref.pluginName],
            env: grokEnvironment(home: home),
            mapCommandError: { grokMutationFailure($0, executable: executable) }
        ) {
        case .success:
            return AgentPluginActionOutcome(status: .disabled)
        case .failure(let outcome):
            return outcome
        }
    }

    // MARK: Uninstall

    func grokUninstall(setup: AgentIntegrationSetup) async -> AgentPluginActionOutcome {
        let setup = effectiveSetupForRecordedInstall(provider: .grok, current: setup)
        let executable = resolvedExecutable(provider: .grok, setup: setup)
        let home = grokHome(setup: setup)
        guard let ref = effectiveRefForRecordedInstall(provider: .grok)
            ?? (try? marketplaceRef(provider: .grok)) else {
            return AgentPluginActionOutcome(status: .unsupported("Bundled Grok plugin manifest is missing"))
        }

        switch await runMutation(
            executable: executable,
            args: ["plugin", "uninstall", ref.pluginName, "--confirm"],
            env: grokEnvironment(home: home),
            mapCommandError: { grokMutationFailure($0, executable: executable) }
        ) {
        case .success:
            try? removeInstallRecord(provider: .grok)
            return AgentPluginActionOutcome(status: .notInstalled)
        case .failure(let outcome):
            return outcome
        }
    }

    // MARK: Confirmation copy

    func grokConfirmationTitle(_ action: AgentPluginAction) -> String {
        switch action {
        case .enableOrInstall: "Install the Grok status plugin"
        case .repair: "Repair the Grok status plugin"
        case .disable: "Disable the Grok status plugin"
        case .uninstall: "Remove the Grok status plugin"
        }
    }

    func grokCommandLines(_ action: AgentPluginAction, ref: AgentPluginMarketplaceRef) -> [String] {
        switch action {
        case .enableOrInstall, .repair:
            [
                "grok plugin validate [generated awesoMux plugin path]",
                "grok plugin install [generated awesoMux plugin path] --trust"
            ]
        case .disable:
            ["grok plugin disable \(ref.pluginName)"]
        case .uninstall:
            ["grok plugin uninstall \(ref.pluginName) --confirm"]
        }
    }

    // MARK: GROK_HOME

    func grokHome(setup: AgentIntegrationSetup) -> URL {
        if let configHome = setup.configHome?.trimmingCharacters(in: .whitespacesAndNewlines), !configHome.isEmpty {
            return URL(fileURLWithPath: (configHome as NSString).expandingTildeInPath)
        }
        return homeDirectoryURL.appending(path: ".grok", directoryHint: .isDirectory)
    }

    private func grokConfigHomeDriftNote(live liveSetup: AgentIntegrationSetup) -> String? {
        guard let record = installRecord(provider: .grok) else { return nil }
        let recordedHome = record.configHome
        let liveHome = grokHome(setup: liveSetup).path
        guard recordedHome != liveHome else { return nil }
        return "Actions target the recorded Grok home \(recordedHome); the Config home field now points at \(liveHome). Repair to move the install, or restore the field to keep using the recorded home."
    }

    private func grokMissingHomeGuidance(home: URL) -> String {
        "GROK_HOME does not exist: \(home.path). Point the Config home field at an existing directory (or clear it for ~/.grok), then Repair"
    }

    private func grokEnvironment(home: URL) -> [String: String] {
        [
            "GROK_HOME": home.path,
            "PATH": mergedToolPath()
        ]
    }

    private func grokPluginDirectory(
        tree: AgentPluginRenderedTree,
        ref: AgentPluginMarketplaceRef
    ) -> URL {
        tree.marketplaceRootURL
            .appending(path: "plugins", directoryHint: .isDirectory)
            .appending(path: ref.pluginName, directoryHint: .isDirectory)
    }

    private func grokDirectoryExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return renderer.fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

// MARK: - Grok plugin list parsing

struct GrokPluginListEntry: Decodable, Equatable, Sendable {
    var status: String?
    var name: String
    var repoKey: String?
    var version: String?
    var path: String?
    var source: String?
    var marketplace: String?

    enum CodingKeys: String, CodingKey {
        case status
        case name
        case repoKey = "repo_key"
        case version
        case path
        case source
        case marketplace
    }

    func matches(_ ref: AgentPluginMarketplaceRef) -> Bool {
        name == ref.pluginName || name == ref.pluginRef
    }
}

enum GrokPluginList {
    static func parse(_ stdout: String) throws -> [GrokPluginListEntry] {
        try JSONDecoder().decode([GrokPluginListEntry].self, from: Data(stdout.utf8))
    }
}

/// Detects installed Grok status plugins whose `hooks/hooks.json` still uses
/// legacy snake_case event keys. Grok's runtime only dispatches CamelCase
/// Claude-style names (`UserPromptSubmit`, …); snake_case installs stay quiet
/// and leave the sidebar stuck on idle even though the plugin is "enabled".
enum GrokInstalledHooksInspector {
    /// Events the bundled plugin must register for the sidebar lifecycle.
    /// Keep in sync with `Resources/AgentIntegrations/grok/.../hooks/hooks.json`.
    static let requiredEventNames: Set<String> = [
        "SessionStart",
        "UserPromptSubmit",
        "PreToolUse",
        "PostToolUse",
        "SubagentStart",
        "SubagentStop",
        "PermissionDenied",
        "Notification",
        "Stop",
        "SessionEnd",
        "StopFailure",
    ]

    /// Max size for a status-time hooks.json read (DoS / special-file guard).
    static let maximumHooksJSONByteCount = 256 * 1024

    /// Returns repair guidance when the on-disk plugin hooks are known-stale.
    /// Returns `nil` when the install looks current, or when the CLI gave no
    /// path (cannot verify). A non-empty absolute path that cannot yield a
    /// readable hooks tree is Needs Repair — silent "enabled" with a broken
    /// install is worse than a transient FS blip.
    static func repairGuidanceIfStale(
        pluginDirectoryPath: String?,
        allowedHome: URL? = nil,
        fileManager: FileManager = .default
    ) -> String? {
        let trimmed = pluginDirectoryPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            return nil
        }

        // Relative paths resolve against process CWD — refuse rather than open
        // arbitrary locations named by untrusted CLI JSON.
        guard trimmed.hasPrefix("/") else {
            return "The Grok status plugin path is not absolute; Repair to reinstall under GROK_HOME"
        }

        let pluginDirectory = URL(fileURLWithPath: trimmed, isDirectory: true)
            .standardizedFileURL
        if let allowedHome {
            let homePath = allowedHome.standardizedFileURL.path
            let pluginPath = pluginDirectory.path
            let underHome = pluginPath == homePath
                || pluginPath.hasPrefix(homePath.hasSuffix("/") ? homePath : homePath + "/")
            // Also allow the common install root ~/.grok/installed-plugins when
            // GROK_HOME is the parent of that tree (default layout).
            guard underHome else {
                return "The Grok status plugin path is outside GROK_HOME; Repair to reinstall under the configured home"
            }
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: pluginDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return "The Grok status plugin directory is missing; Repair to reinstall the current plugin"
        }

        let hooksURL = pluginDirectory
            .appending(path: "hooks", directoryHint: .isDirectory)
            .appending(path: "hooks.json", directoryHint: .notDirectory)

        guard fileManager.fileExists(atPath: hooksURL.path) else {
            return "The Grok status plugin is missing hooks/hooks.json; Repair to reinstall the current plugin"
        }

        let attrs = try? fileManager.attributesOfItem(atPath: hooksURL.path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? -1
        guard size >= 0, size <= maximumHooksJSONByteCount else {
            return "The Grok status plugin hooks file is unreadable; Repair to reinstall the current plugin"
        }

        guard let data = try? Data(contentsOf: hooksURL),
              data.count <= maximumHooksJSONByteCount,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any]
        else {
            return "The Grok status plugin hooks file is unreadable; Repair to reinstall the current plugin"
        }

        let eventNames = Set(hooks.keys)
        guard !requiredEventNames.isSubset(of: eventNames) else {
            return nil
        }

        let hasLegacySnakeCase = eventNames.contains { $0.contains("_") }
        if hasLegacySnakeCase {
            return "The installed Grok status plugin still uses legacy snake_case hook names; Repair to reinstall the current CamelCase hooks so the sidebar reflects agent activity"
        }
        return "The installed Grok status plugin is missing required lifecycle hooks; Repair to reinstall the current plugin"
    }
}
