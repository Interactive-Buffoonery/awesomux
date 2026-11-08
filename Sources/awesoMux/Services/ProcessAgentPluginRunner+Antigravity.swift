import AwesoMuxConfig
import Foundation

// MARK: - Antigravity path

extension ProcessAgentPluginRunner {
    // MARK: Status

    func antigravityStatus(setup liveSetup: AgentIntegrationSetup) async -> AgentPluginStatusReport {
        await antigravityStatusReport(setup: liveSetup)
    }

    private func antigravityStatusReport(
        setup liveSetup: AgentIntegrationSetup
    ) async -> AgentPluginStatusReport {
        let setup = effectiveSetupForRecordedInstall(provider: .antigravity, current: liveSetup)
        let executable = resolvedExecutable(provider: .antigravity, setup: setup)
        let home = antigravityHome(setup: setup)

        if let configured = setup.configHome?.trimmingCharacters(in: .whitespacesAndNewlines),
            !configured.isEmpty,
            !antigravityDirectoryExists(home)
        {
            return AgentPluginStatusReport(
                status: .needsRepair(antigravityMissingHomeGuidance(home: home)),
                presence: .absent
            )
        }

        guard
            let ref = effectiveRefForRecordedInstall(provider: .antigravity, setup: setup)
                ?? (try? marketplaceRef(provider: .antigravity))
        else {
            return AgentPluginStatusReport(
                status: .unsupported("Bundled Antigravity plugin manifest is missing")
            )
        }

        let args = antigravityArgs(["plugin", "list", "--json"], home: home)
        let result: CommandResult
        do {
            result = try await commandRunner.run(
                executable: executable,
                args: args,
                env: antigravityEnvironment(home: home),
                cwd: nil
            )
        } catch let error as CommandRunnerError {
            return antigravityProbeFailure(error, executable: executable)
        } catch {
            return AgentPluginStatusReport(status: .unsupported(error.localizedDescription))
        }

        guard result.isSuccess else {
            return AgentPluginStatusReport(
                status: .needsRepair("agy plugin list failed; re-install may be required"),
                diagnostics: diagnostics(
                    executable: executable,
                    args: args,
                    result: result,
                    summary: "agy plugin list --json exited \(result.exitCode)"
                )
            )
        }

        return antigravityMapList(
            result.stdout,
            ref: ref,
            hasInstallRecord: installRecord(provider: .antigravity, setup: setup) != nil,
            allowedHome: home
        )
    }

    private func antigravityProbeFailure(
        _ error: CommandRunnerError,
        executable: String
    ) -> AgentPluginStatusReport {
        switch error {
        case .executableNotFound:
            return AgentPluginStatusReport(
                status: .unsupported("The agy CLI was not found at \(executable)")
            )
        case .spawnFailed(_, let reason):
            return AgentPluginStatusReport(
                status: .unsupported("agy could not be started at \(executable): \(reason)")
            )
        case .outputTruncated:
            return AgentPluginStatusReport(status: .unsupported(error.localizedDescription))
        case .timedOut:
            return AgentPluginStatusReport(status: .unsupported("agy plugin list timed out"))
        }
    }

    private func antigravityMutationFailure(
        _ error: CommandRunnerError,
        executable: String
    ) -> AgentPluginStatus {
        switch error {
        case .executableNotFound:
            return .unsupported("The agy CLI was not found at \(executable)")
        case .spawnFailed(_, let reason):
            return .unsupported("agy could not be started at \(executable): \(reason)")
        case .outputTruncated:
            return .needsRepair(error.localizedDescription)
        case .timedOut:
            return .unsupported("agy timed out")
        }
    }

    private func antigravityMapList(
        _ stdout: String,
        ref: AgentPluginMarketplaceRef,
        hasInstallRecord: Bool,
        allowedHome: URL
    ) -> AgentPluginStatusReport {
        let entries: [AntigravityPluginListEntry]
        do {
            entries = try AntigravityPluginList.parse(stdout)
        } catch {
            return AgentPluginStatusReport(
                status: .unsupported("This agy version does not support plugin list --json")
            )
        }

        guard let entry = entries.first(where: { $0.matches(ref) }) else {
            return AgentPluginStatusReport(
                status: hasInstallRecord
                    ? .needsRepair(
                        "awesoMux's Antigravity plugin was installed but Antigravity reports no matching plugin; repair or remove it"
                    )
                    : .notInstalled,
                presence: .absent
            )
        }

        if entry.enabled == false {
            return AgentPluginStatusReport(status: .disabled)
        }

        if let guidance = AntigravityInstalledHooksInspector.repairGuidanceIfStale(
            pluginDirectoryPath: entry.path,
            allowedHome: allowedHome,
            fileManager: renderer.fileManager
        ) {
            return AgentPluginStatusReport(status: .needsRepair(guidance), presence: .present)
        }

        if let guidance = outdatedSourceContentGuidance(
            provider: .antigravity,
            configHome: allowedHome.path
        ) {
            return AgentPluginStatusReport(status: .updateAvailable(guidance))
        }

        return AgentPluginStatusReport(status: .enabled)
    }

    // MARK: Enable / install

    func antigravityEnableOrInstall(setup: AgentIntegrationSetup) async -> AgentPluginActionOutcome {
        let executable = resolvedExecutable(provider: .antigravity, setup: setup)
        let home = antigravityHome(setup: setup)

        if let configured = setup.configHome?.trimmingCharacters(in: .whitespacesAndNewlines),
            !configured.isEmpty,
            !antigravityDirectoryExists(home)
        {
            return AgentPluginActionOutcome(
                status: .needsRepair(antigravityMissingHomeGuidance(home: home))
            )
        }

        let tree: AgentPluginRenderedTree
        let ref: AgentPluginMarketplaceRef
        do {
            tree = try renderedTree(provider: .antigravity, setup: setup)
            ref = try AgentPluginMarketplaceRef.read(
                fromRenderedTreeAt: tree.marketplaceRootURL,
                fileManager: renderer.fileManager
            )
        } catch AgentPluginRunnerError.helperPathUnavailable {
            return AgentPluginActionOutcome(
                status: .unsupported("The bundled status helper could not be resolved")
            )
        } catch {
            return AgentPluginActionOutcome(
                status: .needsRepair(
                    "Rendering the Antigravity plugin failed: \(error.localizedDescription)"
                )
            )
        }

        let pluginDirectory = antigravityPluginDirectory(tree: tree, ref: ref)
        let env = antigravityEnvironment(home: home)
        let steps: [MutationStep] = [
            MutationStep(
                antigravityArgs(["plugin", "validate", pluginDirectory.path], home: home),
                mutates: false
            ),
            MutationStep(
                antigravityArgs(["plugin", "install", pluginDirectory.path], home: home)
            ),
            MutationStep(
                antigravityArgs(["plugin", "enable", ref.pluginName], home: home)
            ),
        ]
        if let failure = await runMutationSteps(
            executable: executable,
            steps: steps,
            env: env,
            repairGuidance: "Install failed partway through; use Repair to reconcile",
            mapCommandError: { antigravityMutationFailure($0, executable: $1) }
        ) {
            return failure
        }

        let recordWarning = recordInstallWarning(
            provider: .antigravity,
            setup: setup,
            tree: tree,
            ref: ref
        )
        return AgentPluginActionOutcome(
            status: .enabled,
            guidance: [recordWarning, "Restart open Antigravity sessions to pick this up"]
                .compactMap { $0 }
                .joined(separator: "\n")
        )
    }

    // MARK: Disable

    func antigravityDisable(setup: AgentIntegrationSetup) async -> AgentPluginActionOutcome {
        let setup = effectiveSetupForRecordedInstall(provider: .antigravity, current: setup)
        let executable = resolvedExecutable(provider: .antigravity, setup: setup)
        let home = antigravityHome(setup: setup)
        guard
            let ref = effectiveRefForRecordedInstall(provider: .antigravity, setup: setup)
                ?? (try? marketplaceRef(provider: .antigravity))
        else {
            return AgentPluginActionOutcome(
                status: .unsupported("Bundled Antigravity plugin manifest is missing")
            )
        }

        switch await runMutation(
            executable: executable,
            args: antigravityArgs(["plugin", "disable", ref.pluginName], home: home),
            env: antigravityEnvironment(home: home),
            mapCommandError: { antigravityMutationFailure($0, executable: $1) }
        ) {
        case .success:
            return AgentPluginActionOutcome(status: .disabled)
        case .failure(let outcome):
            return outcome
        }
    }

    // MARK: Uninstall

    func antigravityUninstall(setup: AgentIntegrationSetup) async -> AgentPluginActionOutcome {
        let setup = effectiveSetupForRecordedInstall(provider: .antigravity, current: setup)
        let executable = resolvedExecutable(provider: .antigravity, setup: setup)
        let home = antigravityHome(setup: setup)
        guard
            let ref = effectiveRefForRecordedInstall(provider: .antigravity, setup: setup)
                ?? (try? marketplaceRef(provider: .antigravity))
        else {
            return AgentPluginActionOutcome(
                status: .unsupported("Bundled Antigravity plugin manifest is missing")
            )
        }

        switch await runMutation(
            executable: executable,
            args: antigravityArgs(["plugin", "uninstall", ref.pluginName], home: home),
            env: antigravityEnvironment(home: home),
            mapCommandError: { antigravityMutationFailure($0, executable: $1) }
        ) {
        case .success:
            try? removeInstallRecord(provider: .antigravity, setup: setup)
            return AgentPluginActionOutcome(status: .notInstalled)
        case .failure(let outcome):
            return outcome
        }
    }

    // MARK: Confirmation copy

    func antigravityConfirmationTitle(_ action: AgentPluginAction) -> String {
        switch action {
        case .enableOrInstall:
            String(
                localized: "Install the Antigravity status plugin",
                comment: "Confirmation dialog title for the Antigravity status plugin action")
        case .repair:
            String(
                localized: "Repair the Antigravity status plugin",
                comment: "Confirmation dialog title for the Antigravity status plugin action")
        case .disable:
            String(
                localized: "Disable the Antigravity status plugin",
                comment: "Confirmation dialog title for the Antigravity status plugin action")
        case .uninstall:
            String(
                localized: "Remove the Antigravity status plugin",
                comment: "Confirmation dialog title for the Antigravity status plugin action")
        }
    }

    func antigravityCommandLines(
        _ action: AgentPluginAction,
        ref: AgentPluginMarketplaceRef
    ) -> [String] {
        switch action {
        case .enableOrInstall, .repair:
            [
                "agy plugin validate [generated awesoMux plugin path]",
                "agy plugin install [generated awesoMux plugin path]",
                "agy plugin enable \(ref.pluginName)",
            ]
        case .disable:
            ["agy plugin disable \(ref.pluginName)"]
        case .uninstall:
            ["agy plugin uninstall \(ref.pluginName)"]
        }
    }

    // MARK: Config home

    func antigravityHome(setup: AgentIntegrationSetup) -> URL {
        AgentConfigHome.url(
            setup: setup,
            defaultDirectoryName: ".gemini",
            homeDirectoryURL: homeDirectoryURL
        )
    }

    private func antigravityArgs(_ subcommandArgs: [String], home: URL) -> [String] {
        ["--gemini_dir=\(home.path)"] + subcommandArgs
    }

    private func antigravityMissingHomeGuidance(home: URL) -> String {
        "Antigravity config home does not exist: \(home.path). Point the Config home field at an existing directory (or clear it for ~/.gemini), then Repair"
    }

    private func antigravityEnvironment(home: URL) -> [String: String] {
        [
            "PATH": mergedToolPath()
        ]
    }

    private func antigravityPluginDirectory(
        tree: AgentPluginRenderedTree,
        ref: AgentPluginMarketplaceRef
    ) -> URL {
        tree.marketplaceRootURL
            .appending(path: "plugins", directoryHint: .isDirectory)
            .appending(path: ref.pluginName, directoryHint: .isDirectory)
    }

    private func antigravityDirectoryExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return renderer.fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}

// MARK: - Antigravity plugin list parsing

struct AntigravityPluginListEntry: Decodable, Equatable, Sendable {
    var name: String
    var enabled: Bool?
    var version: String?
    var source: String?
    var path: String?
    var hooks: [String]?

    func matches(_ ref: AgentPluginMarketplaceRef) -> Bool {
        name == ref.pluginName || name == ref.pluginRef
    }
}

enum AntigravityPluginList {
    static func parse(_ stdout: String) throws -> [AntigravityPluginListEntry] {
        try JSONDecoder().decode([AntigravityPluginListEntry].self, from: Data(stdout.utf8))
    }
}

/// Inspects an installed Antigravity status plugin's `hooks.json` so structural
/// corruption or missing lifecycle hooks surface as Needs Repair rather than
/// silently reading Enabled.
enum AntigravityInstalledHooksInspector {
    /// Events the bundled plugin must register for the sidebar lifecycle.
    /// Keep in sync with `Resources/AgentIntegrations/antigravity/.../hooks.json`.
    static let requiredEventNames: Set<String> = [
        "SessionStart",
        "PreInvocation",
        "PostToolUse",
        "Stop",
    ]

    /// Max size for a status-time hooks.json read (DoS / special-file guard).
    static let maximumHooksJSONByteCount = 256 * 1024

    static func repairGuidanceIfStale(
        pluginDirectoryPath: String?,
        allowedHome: URL? = nil,
        fileManager: FileManager = .default
    ) -> String? {
        let trimmed = pluginDirectoryPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            return nil
        }

        guard trimmed.hasPrefix("/") else {
            return
                "The Antigravity status plugin path is not absolute; Repair to reinstall under the configured home"
        }

        let pluginDirectory = URL(fileURLWithPath: trimmed, isDirectory: true)
            .standardizedFileURL
        if let allowedHome {
            let homePath = allowedHome.standardizedFileURL.path
            let pluginPath = pluginDirectory.path
            let underHome =
                pluginPath == homePath
                || pluginPath.hasPrefix(homePath.hasSuffix("/") ? homePath : homePath + "/")
            guard underHome else {
                return
                    "The Antigravity status plugin path is outside the configured home; Repair to reinstall under the configured home"
            }
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: pluginDirectory.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            return
                "The Antigravity status plugin directory is missing; Repair to reinstall the current plugin"
        }

        let hooksURL = pluginDirectory.appending(path: "hooks.json", directoryHint: .notDirectory)

        guard fileManager.fileExists(atPath: hooksURL.path) else {
            return
                "The Antigravity status plugin is missing hooks.json; Repair to reinstall the current plugin"
        }

        let attrs = try? fileManager.attributesOfItem(atPath: hooksURL.path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? -1
        guard size >= 0, size <= maximumHooksJSONByteCount else {
            return
                "The Antigravity status plugin hooks file is unreadable; Repair to reinstall the current plugin"
        }

        guard let data = try? Data(contentsOf: hooksURL),
            data.count <= maximumHooksJSONByteCount,
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return
                "The Antigravity status plugin hooks file is unreadable; Repair to reinstall the current plugin"
        }

        var eventNames: Set<String> = []
        for value in root.values {
            if let group = value as? [String: Any] {
                eventNames.formUnion(group.keys)
            }
        }

        guard !requiredEventNames.isSubset(of: eventNames) else {
            return nil
        }

        return
            "The installed Antigravity status plugin is missing required lifecycle hooks; Repair to reinstall the current plugin"
    }
}
