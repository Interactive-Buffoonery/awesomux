import AwesoMuxConfig
import Foundation

// MARK: - Install manifest persistence

extension ProcessAgentPluginRunner {
    /// Global awesoMux-owned record of CLI-driven installs. Rendered trees stay
    /// profile-scoped, while this record follows the provider state all profiles
    /// mutate. Separate file from the file-drop installer's
    /// `install-manifest.json` so the two install machineries never collide.
    var pluginManifestURL: URL {
        installStateDirectoryURL.appending(path: "plugin-install-manifest.json")
    }

    private var pluginManifestStore: AgentInstallManifestStore<AgentPluginInstallManifest> {
        AgentInstallManifestStore(
            manifestURL: pluginManifestURL,
            legacyManifestURL: legacyInstallStateDirectoryURL.appending(path: "plugin-install-manifest.json"),
            fileManager: renderer.fileManager
        )
    }

    func loadInstallManifest() -> AgentPluginInstallManifest {
        switch pluginManifestStore.loadState() {
        case .missing, .failed:
            return .empty
        case .loaded(let manifest):
            return manifest
        }
    }

    func installManifestLoadWarning() -> String? {
        switch pluginManifestStore.loadState() {
        case .failed(.unreadable):
            return String(
                localized: "The install record could not be read. Agent integration changes are blocked until it is accessible.",
                comment: "Unreadable CLI agent plugin install manifest warning"
            )
        case .failed(.corrupt):
            return String(
                localized: "The install record is corrupt. Agent integration changes are blocked to protect existing installs.",
                comment: "Corrupt CLI agent plugin install manifest warning"
            )
        case .failed(.busy):
            return String(
                localized: "Another awesoMux instance is changing agent integrations; try again.",
                comment: "CLI agent plugin install state lock contention warning"
            )
        case .failed(.unavailable):
            return String(
                localized: "The install state is temporarily unavailable. Agent integration changes are blocked.",
                comment: "Unavailable CLI agent plugin install state warning"
            )
        case .failed(.recoverableUnsupportedVersion(let version)):
            return String(
                localized:
                    "Install record format \(version) needs repair. The next agent integration change will back it up and rebuild it.",
                comment: "Recoverable empty CLI agent plugin install manifest warning"
            )
        case .failed(.unsupportedVersion(let version)):
            return String(
                localized:
                    "Install record format \(version) is not supported by this version of awesoMux. Agent integration changes are blocked.",
                comment: "Unsupported CLI agent plugin install manifest warning"
            )
        case .missing, .loaded:
            return nil
        }
    }

    func prepareInstallManifestForMutation() throws {
        try pluginManifestStore.importLegacyIfNeededAssumingLock()
        _ = try pluginManifestStore.loadForMutationRecoveringEmptyUnsupported()
    }

    func recordInstall(
        provider: AgentPluginProvider,
        setup: AgentIntegrationSetup,
        tree: AgentPluginRenderedTree,
        ref: AgentPluginMarketplaceRef
    ) throws {
        let configHome: String
        switch provider {
        case .claudeCode:
            configHome = claudeConfigHome(setup: setup).path
        case .codex:
            configHome = codexHome(setup: setup).path
        case .grok:
            configHome = grokHome(setup: setup).path
        }

        let record = AgentPluginInstallRecord(
            provider: provider,
            binaryPath: resolvedExecutable(provider: provider, setup: setup),
            configHome: configHome,
            marketplaceRoot: tree.marketplaceRootURL.path,
            helperPath: tree.helperPath,
            marketplaceName: ref.marketplaceName,
            pluginName: ref.pluginName,
            sourceContentDigest: AgentPluginSourceFingerprint.digest(
                provider: provider,
                resourcesDirectoryURL: renderer.resourcesDirectoryURL,
                fileManager: renderer.fileManager
            )
        )

        var manifest = try pluginManifestStore.loadCurrent()
        manifest.records.removeAll { $0.provider == provider }
        manifest.records.append(record)
        try saveInstallManifest(manifest)
    }

    /// Records the install, returning a user-facing warning if the bookkeeping
    /// write failed. The provider CLI already installed the plugin, so a failed
    /// manifest write must not fail the op — but it must be surfaced: without the
    /// record, a later Disable/Uninstall falls back to the live settings instead
    /// of the config home the install actually targeted, and can act on the wrong
    /// directory (the exact drift the manifest exists to prevent).
    func recordInstallWarning(
        provider: AgentPluginProvider,
        setup: AgentIntegrationSetup,
        tree: AgentPluginRenderedTree,
        ref: AgentPluginMarketplaceRef
    ) -> String? {
        do {
            try recordInstall(provider: provider, setup: setup, tree: tree, ref: ref)
            return nil
        } catch {
            return
                "Installed, but the install record could not be saved. Disable and Remove may target your current settings instead of where this was installed."
        }
    }

    func removeInstallRecord(provider: AgentPluginProvider) throws {
        var manifest = try pluginManifestStore.loadCurrent()
        manifest.records.removeAll { $0.provider == provider }
        try saveInstallManifest(manifest)
    }

    func installRecord(provider: AgentPluginProvider) -> AgentPluginInstallRecord? {
        loadInstallManifest().record(for: provider)
    }

    func effectiveSetupForRecordedInstall(
        provider: AgentPluginProvider,
        current setup: AgentIntegrationSetup
    ) -> AgentIntegrationSetup {
        guard let record = installRecord(provider: provider) else {
            return setup
        }
        return AgentIntegrationSetup(
            enabled: setup.enabled,
            binaryPath: record.binaryPath,
            configHome: record.configHome
        )
    }

    func effectiveRefForRecordedInstall(provider: AgentPluginProvider) -> AgentPluginMarketplaceRef? {
        installRecord(provider: provider)?.pluginRef
    }

    private func saveInstallManifest(_ manifest: AgentPluginInstallManifest) throws {
        try pluginManifestStore.save(manifest)
    }
}

// MARK: - AgentPluginProvider display + defaults

extension AgentPluginProvider {
    var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .grok: "Grok"
        }
    }

    var subtitle: String {
        switch self {
        case .claudeCode: "Status plugin"
        case .codex: "Status hook"
        case .grok: "Status plugin"
        }
    }

    var defaultBinaryPath: String {
        switch self {
        case .claudeCode: "claude"
        case .codex: "codex"
        case .grok: "grok"
        }
    }

    /// The default config home shown as a placeholder (Claude `~/.claude`, Codex
    /// `CODEX_HOME` → `~/.codex`).
    var defaultConfigHomePlaceholder: String {
        switch self {
        case .claudeCode: "~/.claude"
        case .codex: "~/.codex"
        case .grok: "~/.grok"
        }
    }

    /// The label for the config-home field — Codex's is literally `CODEX_HOME`.
    var configHomeLabel: String {
        switch self {
        case .claudeCode: "Config home"
        case .codex: "CODEX_HOME"
        case .grok: "GROK_HOME"
        }
    }

    /// The marketplace name baked into the bundled `marketplace.json`, used only
    /// as a confirmation-copy fallback when no rendered tree exists yet
    /// (decision 6 derives the live value from the rendered manifest).
    var fallbackMarketplaceName: String {
        switch self {
        case .claudeCode: "awesomux-claude"
        case .codex: "awesomux-codex"
        case .grok: "awesomux-grok"
        }
    }

    var fallbackPluginName: String {
        switch self {
        case .claudeCode: "awesomux-claude-status"
        case .codex: "awesomux-codex-status"
        case .grok: "awesomux-grok-status"
        }
    }
}
