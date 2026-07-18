import AwesoMuxConfig
import Foundation
import os

// MARK: - AgentPluginRunner

/// Orchestrates install/status/enable/disable/uninstall for the CLI-driven agent
/// providers (Claude Code, Codex), composing the INT-519 primitives —
/// `CommandRunner`, the Codex app-server client, and `AgentPluginTemplateRenderer`
/// — into the operations the settings cards drive. See ADR-0012 and the
/// agent-status-plugin-install-contract.
///
/// The consent boundary (decision 1) lives here: `status(provider:setup:)` runs
/// only read-only probes (`claude plugin list --json`, Codex `hooks/list`,
/// `codex doctor`) and renders into awesoMux's own support dir; mutations
/// (`marketplace add`, `install`, `enable`/`disable`, `uninstall`,
/// `config/batchWrite`) happen only through the explicit action ops. Nothing in a
/// status read writes provider state.
protocol AgentPluginRunner: Sendable {
    func status(
        provider: AgentPluginProvider,
        setup: AgentIntegrationSetup
    ) async -> AgentPluginStatusReport

    func enableOrInstall(
        provider: AgentPluginProvider,
        setup: AgentIntegrationSetup
    ) async -> AgentPluginActionOutcome

    func repair(
        provider: AgentPluginProvider,
        setup: AgentIntegrationSetup
    ) async -> AgentPluginActionOutcome

    func disable(
        provider: AgentPluginProvider,
        setup: AgentIntegrationSetup
    ) async -> AgentPluginActionOutcome

    func uninstall(
        provider: AgentPluginProvider,
        setup: AgentIntegrationSetup
    ) async -> AgentPluginActionOutcome

    /// The exact targets a mutation will touch, as data the confirmation sheet
    /// renders verbatim. Pure: computes paths and refs without writing anything
    /// (no render, no CLI), so it never crosses the consent boundary.
    func confirmation(
        for action: AgentPluginAction,
        provider: AgentPluginProvider,
        setup: AgentIntegrationSetup
    ) -> AgentPluginConfirmation
}

// MARK: - AgentPluginAction

/// The mutating operations gated behind the confirmation sheet.
enum AgentPluginAction: Equatable, Sendable {
    case enableOrInstall
    case repair
    case disable
    case uninstall
}

// MARK: - AgentPluginConfirmation

/// What a mutation will touch, surfaced before the user confirms. The command
/// lines are human-readable intent strings, not the literal argv (the runner owns
/// argv); they name the executable and the resolved target so the sheet shows
/// "what runs where".
struct AgentPluginConfirmation: Equatable, Sendable {
    var action: AgentPluginAction
    var title: String
    var executablePath: String
    /// The config target(s) the op affects — Claude `--scope user` settings home,
    /// or the resolved Codex `CODEX_HOME`.
    var configTargets: [String]
    /// Human command-intent lines rendered verbatim, e.g.
    /// "claude plugin install awesomux-claude-status@awesomux-claude --scope user".
    var commandLines: [String]
}

// MARK: - CodexAppServerClientFactory

/// Spawns a fresh app-server client per Codex op (decision 3, spawn-per-op). Prod
/// wires `ProcessCodexAppServerClient.spawning`; tests inject a closure returning
/// a `StubCodexAppServerClient`. Throws `CodexAppServerError.appServerUnavailable`
/// when the subcommand cannot be started — the version-skew → `Unsupported` path.
typealias CodexAppServerClientFactory =
    @Sendable (
        _ codexExecutable: String,
        _ codexHome: String
    ) throws -> CodexAppServerClient

// MARK: - ProcessAgentPluginRunner

struct ProcessAgentPluginRunner: AgentPluginRunner {
    var commandRunner: CommandRunner
    var renderer: AgentPluginTemplateRenderer
    var codexClientFactory: CodexAppServerClientFactory
    var homeDirectoryURL: URL
    var helperPathResolver: @Sendable () -> AgentHookHelperPath?
    var installStateDirectoryURL: URL
    var legacyInstallStateDirectoryURL: URL

    private static let logger = Logger(
        subsystem: "com.interactivebuffoonery.awesomux",
        category: "AgentPluginRunner"
    )

    init(
        commandRunner: CommandRunner = ProcessCommandRunner(),
        renderer: AgentPluginTemplateRenderer? = nil,
        codexClientFactory: @escaping CodexAppServerClientFactory = { executable, home in
            // Resolve a bare `codex` against the same PATH the CLI mutation path
            // uses (defaults + live process PATH), so status and enable/uninstall
            // find the binary in the same places. Defaulting the transport to the
            // defaults-only PATH would let enable succeed while status reports the
            // binary missing for a codex installed via nvm/asdf.
            try ProcessCodexAppServerClient.spawning(
                codexExecutable: executable,
                codexHome: home,
                searchPath: ProcessAgentPluginRunner.mergeToolPath(
                    processPath: ProcessInfo.processInfo.environment["PATH"]
                )
            )
        },
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        helperPathResolver: @escaping @Sendable () -> AgentHookHelperPath? = { AgentHookHelperPath.resolve() },
        installStateDirectoryURL: URL? = nil,
        legacyInstallStateDirectoryURL: URL? = nil
    ) {
        let resolvedRenderer = renderer ?? AgentPluginTemplateRenderer()
        let resolvedInstallStateDirectoryURL =
            installStateDirectoryURL
            ?? (renderer == nil
                ? AgentIntegrationInstallStateLocation.canonicalDirectoryURL
                : resolvedRenderer.rootDirectoryURL)
        self.commandRunner = commandRunner
        self.renderer = resolvedRenderer
        self.codexClientFactory = codexClientFactory
        self.homeDirectoryURL = homeDirectoryURL
        self.helperPathResolver = helperPathResolver
        self.installStateDirectoryURL = resolvedInstallStateDirectoryURL
        self.legacyInstallStateDirectoryURL =
            legacyInstallStateDirectoryURL
            ?? (renderer == nil && installStateDirectoryURL == nil
                ? AgentIntegrationInstallStateLocation.legacyDevelopmentDirectoryURL
                : resolvedInstallStateDirectoryURL)
    }

    // MARK: Status

    func status(
        provider: AgentPluginProvider,
        setup: AgentIntegrationSetup
    ) async -> AgentPluginStatusReport {
        var report: AgentPluginStatusReport
        switch provider {
        case .claudeCode:
            report = await claudeStatus(setup: setup)
        case .codex:
            report = await codexStatus(setup: setup)
        case .grok:
            report = await grokStatus(setup: setup)
        }
        report.note = Self.mergedStatusNote(report.note, installManifestLoadWarning())
        return report
    }

    private static func mergedStatusNote(_ existing: String?, _ addition: String?) -> String? {
        guard let addition else { return existing }
        guard let existing, !existing.isEmpty else { return addition }
        return existing + "\n" + addition
    }

    // MARK: Actions

    func enableOrInstall(
        provider: AgentPluginProvider,
        setup: AgentIntegrationSetup
    ) async -> AgentPluginActionOutcome {
        await withInstallStateLock {
            switch provider {
            case .claudeCode:
                await claudeEnableOrInstall(setup: setup)
            case .codex:
                await codexEnableOrInstall(setup: setup)
            case .grok:
                await grokEnableOrInstall(setup: setup)
            }
        }
    }

    func repair(
        provider: AgentPluginProvider,
        setup: AgentIntegrationSetup
    ) async -> AgentPluginActionOutcome {
        // Repair re-renders and re-installs in place; the enable/install path is
        // idempotent (`marketplace add` re-validates, `install` re-enables), so it
        // doubles as repair.
        await enableOrInstall(provider: provider, setup: setup)
    }

    func disable(
        provider: AgentPluginProvider,
        setup: AgentIntegrationSetup
    ) async -> AgentPluginActionOutcome {
        await withInstallStateLock {
            switch provider {
            case .claudeCode:
                await claudeDisable(setup: setup)
            case .codex:
                await codexDisable(setup: setup)
            case .grok:
                await grokDisable(setup: setup)
            }
        }
    }

    func uninstall(
        provider: AgentPluginProvider,
        setup: AgentIntegrationSetup
    ) async -> AgentPluginActionOutcome {
        await withInstallStateLock {
            switch provider {
            case .claudeCode:
                await claudeUninstall(setup: setup)
            case .codex:
                await codexUninstall(setup: setup)
            case .grok:
                await grokUninstall(setup: setup)
            }
        }
    }

    private func withInstallStateLock(
        _ operation: () async -> AgentPluginActionOutcome
    ) async -> AgentPluginActionOutcome {
        do {
            let lock = try AgentIntegrationInstallStateLock.acquire(
                in: installStateDirectoryURL,
                fileManager: renderer.fileManager
            )
            defer { lock.release() }
            try prepareInstallManifestForMutation()
            return await operation()
        } catch AgentIntegrationInstallStateLockError.busy {
            return AgentPluginActionOutcome(
                status: .needsRepair(
                    String(
                        localized: "Another awesoMux instance is changing agent integrations; try again",
                        comment: "CLI agent plugin install state lock contention action error"
                    )
                )
            )
        } catch let error as AgentInstallManifestLoadError {
            let message =
                switch error {
                case .unreadable:
                    String(
                        localized: "The global integration install record could not be read",
                        comment: "Unreadable CLI agent plugin install manifest action error"
                    )
                case .corrupt:
                    String(
                        localized: "The global integration install record is corrupt",
                        comment: "Corrupt CLI agent plugin install manifest action error"
                    )
                case .busy:
                    String(
                        localized: "Another awesoMux instance is changing agent integrations; try again",
                        comment: "CLI agent plugin install state lock contention action error"
                    )
                case .unavailable:
                    String(
                        localized: "The global integration install state is temporarily unavailable",
                        comment: "Unavailable CLI agent plugin install state action error"
                    )
                case .recoverableUnsupportedVersion(let version), .unsupportedVersion(let version):
                    String(
                        localized: "Install record format \(version) is not supported by this version of awesoMux",
                        comment: "Unsupported CLI agent plugin install manifest action error"
                    )
                }
            return AgentPluginActionOutcome(status: .needsRepair(message))
        } catch {
            return AgentPluginActionOutcome(
                status: .needsRepair("The global integration install state is unavailable: \(error.localizedDescription)")
            )
        }
    }

    // MARK: Confirmation

    func confirmation(
        for action: AgentPluginAction,
        provider: AgentPluginProvider,
        setup: AgentIntegrationSetup
    ) -> AgentPluginConfirmation {
        let executable = resolvedExecutable(provider: provider, setup: setup)
        // Derive the ref from the rendered manifest if present; otherwise fall
        // back to the bundled tree's manifest. Reading a manifest is not a
        // mutation — confirmation must not render or shell out.
        let ref =
            (try? marketplaceRef(provider: provider))
            ?? AgentPluginMarketplaceRef(marketplaceName: provider.fallbackMarketplaceName, pluginName: provider.fallbackPluginName)

        switch provider {
        case .claudeCode:
            let settingsHome = claudeConfigHome(setup: setup).path
            return AgentPluginConfirmation(
                action: action,
                title: claudeConfirmationTitle(action),
                executablePath: executable,
                configTargets: [settingsHome.appending("/settings.json")],
                commandLines: claudeCommandLines(action, ref: ref)
            )
        case .codex:
            let codexHome = codexHome(setup: setup).path
            return AgentPluginConfirmation(
                action: action,
                title: codexConfirmationTitle(action),
                executablePath: executable,
                configTargets: [codexHome.appending("/config.toml")],
                commandLines: codexCommandLines(action, ref: ref, codexHome: codexHome)
            )
        case .grok:
            return AgentPluginConfirmation(
                action: action,
                title: grokConfirmationTitle(action),
                executablePath: executable,
                configTargets: [],
                commandLines: grokCommandLines(action, ref: ref)
            )
        }
    }

    // MARK: - Shared helpers

    func resolvedExecutable(provider: AgentPluginProvider, setup: AgentIntegrationSetup) -> String {
        let trimmed = setup.binaryPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            return trimmed
        }
        return provider.defaultBinaryPath
    }

    /// When the user has an install record whose source digest no longer matches
    /// the bundled plugin, surface Needs Repair so Settings offers an update path
    /// after awesoMux ships new hooks.
    ///
    /// - No install record → `nil` (nothing we own to update).
    /// - Record without a digest (pre-fingerprint installs) → one-time Repair
    ///   prompt so the next install records a digest and future app updates can
    ///   alert automatically. Safe: Repair reinstalls the current plugin.
    /// - Recorded digest ≠ current → standard "newer plugin available" Repair.
    func outdatedSourceContentGuidance(provider: AgentPluginProvider) -> String? {
        guard let record = installRecord(provider: provider) else {
            return nil
        }
        guard
            let current = AgentPluginSourceFingerprint.digest(
                provider: provider,
                resourcesDirectoryURL: renderer.resourcesDirectoryURL,
                fileManager: renderer.fileManager
            )
        else {
            return nil
        }
        guard let recorded = record.sourceContentDigest else {
            return AgentPluginSourceFingerprint.legacyInstallMissingDigestGuidance
        }
        guard recorded != current else {
            return nil
        }
        return AgentPluginSourceFingerprint.outdatedInstallGuidance
    }

    /// The prior install record when the provider CLI's installed copy of the
    /// plugin is known-stale relative to a freshly rendered tree: the baked
    /// helper path moved (dev `dist/` → release app, or the app was relocated),
    /// or the bundled hook source changed since that install (a recorded digest
    /// that is `nil` or differs from the current bundled digest). The provider
    /// CLIs key their plugin caches on the manifest version, which awesoMux
    /// never changes, so a plain re-install "succeeds" without re-pulling the
    /// rendered content (INT-651) — the caller must uninstall the recorded
    /// plugin first to force a fresh copy. A current digest that cannot be
    /// computed never counts as drift: a fingerprint failure must not trigger a
    /// destructive uninstall.
    func staleCachedInstallRecord(
        provider: AgentPluginProvider,
        tree: AgentPluginRenderedTree
    ) -> AgentPluginInstallRecord? {
        guard let record = installRecord(provider: provider) else {
            return nil
        }
        if record.helperPath != tree.helperPath {
            return record
        }
        if let current = AgentPluginSourceFingerprint.digest(
            provider: provider,
            resourcesDirectoryURL: renderer.resourcesDirectoryURL,
            fileManager: renderer.fileManager
        ), record.sourceContentDigest != current {
            return record
        }
        return nil
    }

    /// Renders the tree (read-only into awesoMux's own support dir — not a
    /// provider mutation) and reads the marketplace ref out of it. Used by both
    /// status and the action ops.
    func renderedTree(
        provider: AgentPluginProvider,
        setup: AgentIntegrationSetup
    ) throws -> AgentPluginRenderedTree {
        guard let helper = helperPathResolver() else {
            throw AgentPluginRunnerError.helperPathUnavailable
        }
        return try renderer.render(provider: provider, setup: setup, helperPath: helper)
    }

    /// The marketplace ref from the rendered tree if it exists, else the bundled
    /// tree — both carry the same static `marketplace.json`. Pure read.
    func marketplaceRef(provider: AgentPluginProvider) throws -> AgentPluginMarketplaceRef {
        let rendered = renderer.renderedTreeURL(provider: provider)
        if renderer.fileManager.fileExists(atPath: rendered.path) {
            do {
                return try AgentPluginMarketplaceRef.read(
                    fromRenderedTreeAt: rendered,
                    fileManager: renderer.fileManager
                )
            } catch {
                // Treat an unreadable rendered cache like a miss and fall back to
                // the bundled tree, which carries the same static marketplace.json.
            }
        }
        return try AgentPluginMarketplaceRef.read(
            fromRenderedTreeAt: renderer.bundledTreeURL(provider: provider),
            fileManager: renderer.fileManager
        )
    }

    func diagnostics(
        executable: String,
        args: [String],
        result: CommandResult,
        summary: String
    ) -> AgentPluginDiagnostics {
        AgentPluginDiagnostics(
            executablePath: executable,
            args: args,
            exitCode: result.exitCode,
            rawStdout: result.stdout,
            rawStderr: result.stderr,
            summary: summary,
            homeDirectory: homeDirectoryURL
        )
    }

    // MARK: - Shared CLI mutation runner

    /// A single argv-mutation step: whether it changed provider state, so a later
    /// failure can be reported as repairable only when something was actually
    /// mutated (contract §1.2/§2.5). Providers that mutate at every step pass
    /// `mutates: true` throughout.
    struct MutationStep {
        var args: [String]
        var mutates: Bool
        /// Per-step overrides for a step that must target a different binary or
        /// environment than the rest of the sequence — the clean-reinstall
        /// uninstall (INT-651) runs against the *recorded* install, not the
        /// live settings. `nil` uses the sequence-wide values.
        var executable: String?
        var env: [String: String]?

        init(
            _ args: [String],
            mutates: Bool = true,
            executable: String? = nil,
            env: [String: String]? = nil
        ) {
            self.args = args
            self.mutates = mutates
            self.executable = executable
            self.env = env
        }
    }

    enum MutationResult {
        case success
        case failure(AgentPluginActionOutcome)
    }

    /// Runs one CLI mutation and maps its outcome. The `mapCommandError` closure is
    /// the only provider-specific piece: it turns a `CommandRunnerError` into a
    /// status, so Codex keeps timeout→Unsupported and Claude keeps
    /// timeout→needsRepair. The closure receives the executable the failed call
    /// actually ran — a step-level override may differ from the sequence-wide
    /// executable, and "not found at …" must name the right binary. A
    /// present-but-nonzero exit is shared: needsRepair with diagnostics attached.
    func runMutation(
        executable: String,
        args: [String],
        env: [String: String],
        mapCommandError: (CommandRunnerError, String) -> AgentPluginStatus
    ) async -> MutationResult {
        let result: CommandResult
        do {
            result = try await commandRunner.run(executable: executable, args: args, env: env, cwd: nil)
        } catch let error as CommandRunnerError {
            return .failure(AgentPluginActionOutcome(status: mapCommandError(error, executable)))
        } catch {
            return .failure(AgentPluginActionOutcome(status: .unsupported(error.localizedDescription)))
        }

        guard result.isSuccess else {
            return .failure(
                AgentPluginActionOutcome(
                    status: .needsRepair("The command failed; see diagnostics"),
                    diagnostics: diagnostics(
                        executable: executable, args: args, result: result,
                        summary: "\(executable) \(args.joined(separator: " ")) exited \(result.exitCode)"
                    )
                ))
        }
        return .success
    }

    /// Runs a sequence of mutation steps, stopping at the first failure. Once a
    /// state-changing step has succeeded, a later failure is reported as repairable
    /// (with `repairGuidance`) so the user can reconcile a partial install/uninstall
    /// rather than being stranded. Returns `nil` on success.
    func runMutationSteps(
        executable: String,
        steps: [MutationStep],
        env: [String: String],
        repairGuidance: String,
        mapCommandError: (CommandRunnerError, String) -> AgentPluginStatus
    ) async -> AgentPluginActionOutcome? {
        var didMutate = false
        for step in steps {
            switch await runMutation(
                executable: step.executable ?? executable,
                args: step.args,
                env: step.env ?? env,
                mapCommandError: mapCommandError
            ) {
            case .success:
                if step.mutates {
                    didMutate = true
                }
            case .failure(let outcome):
                return didMutate
                    ? outcome.asRepairableFailure(repairGuidance: repairGuidance)
                    : outcome
            }
        }
        return nil
    }

    func mergedToolPath(processPath: String? = nil) -> String {
        // The default (no override) merges the safe defaults with the *process*
        // PATH, which cannot change over a run — so it is computed once and cached
        // module-level. A test-supplied `processPath` bypasses the cache: it varies
        // per call and must never poison the shared value.
        if let processPath {
            return Self.mergeToolPath(processPath: processPath)
        }
        return cachedProcessMergedToolPath
    }

    static func mergeToolPath(processPath: String?) -> String {
        var entries = ProcessCommandRunner.defaultToolPath
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)
        let existing = Set(entries)
        let extras = (processPath ?? "")
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { !existing.contains($0) }
        entries.append(contentsOf: extras)
        return entries.joined(separator: ":")
    }
}

/// Cached merge of the safe defaults with the live process `PATH`. Both inputs are
/// fixed for the lifetime of the process, so the dedup is done once here rather
/// than on every spawn (the runner is a value type, so this can't be a stored
/// property). Test overrides pass an explicit `processPath` and skip this.
private let cachedProcessMergedToolPath: String = ProcessAgentPluginRunner.mergeToolPath(
    processPath: ProcessInfo.processInfo.environment["PATH"]
)

// MARK: - AgentPluginRunnerError

enum AgentPluginRunnerError: Error, Equatable, Sendable {
    /// The running bundle exposes no helper path to bake (e.g. a unit-test host).
    /// Surfaces as `Unsupported` to the card.
    case helperPathUnavailable
}
