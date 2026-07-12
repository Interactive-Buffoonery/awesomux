import AwesoMuxConfig
import Foundation
import os

// MARK: - Install manifest persistence

extension ProcessAgentPluginRunner {
    private static let persistenceLogger = Logger(
        subsystem: "com.interactivebuffoonery.awesomux",
        category: "AgentPluginPersistence"
    )

    /// Global awesoMux-owned record of CLI-driven installs. Rendered trees stay
    /// profile-scoped, while this record follows the provider state all profiles
    /// mutate. Separate file from the file-drop installer's
    /// `install-manifest.json` so the two install machineries never collide.
    var pluginManifestURL: URL {
        installStateDirectoryURL.appending(path: "plugin-install-manifest.json")
    }

    func loadInstallManifest() -> AgentPluginInstallManifest {
        switch loadInstallManifestState() {
        case .missing, .corrupt:
            return .empty
        case .loaded(let manifest):
            return manifest
        }
    }

    func installManifestLoadWarning() -> String? {
        switch loadInstallManifestState() {
        case .corrupt:
            return Self.corruptInstallManifestWarning
        case .missing, .loaded:
            return nil
        }
    }

    private enum InstallManifestLoadState {
        case missing
        case corrupt
        case loaded(AgentPluginInstallManifest)
    }

    private static let corruptInstallManifestWarning =
        "The install record could not be read. Disable and Remove may target your current settings instead of where this was installed."

    private func loadInstallManifestState() -> InstallManifestLoadState {
        try? importLegacyInstallManifestIfNeeded()
        guard renderer.fileManager.fileExists(atPath: pluginManifestURL.path) else {
            return .missing
        }
        guard let data = try? Data(contentsOf: pluginManifestURL) else {
            Self.persistenceLogger.error(
                "failed to read plugin install manifest at \(self.pluginManifestURL.path, privacy: .private)"
            )
            return .corrupt
        }
        guard let manifest = try? JSONDecoder().decode(AgentPluginInstallManifest.self, from: data) else {
            Self.persistenceLogger.error(
                "failed to decode plugin install manifest at \(self.pluginManifestURL.path, privacy: .private)"
            )
            return .corrupt
        }
        return .loaded(manifest)
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

        var manifest = loadInstallManifest()
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
            return "Installed, but the install record could not be saved. Disable and Remove may target your current settings instead of where this was installed."
        }
    }

    func removeInstallRecord(provider: AgentPluginProvider) throws {
        var manifest = loadInstallManifest()
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
        try renderer.fileManager.createDirectory(at: installStateDirectoryURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(manifest)
        try writePrivateManifest(data)
    }

    private func writePrivateManifest(_ data: Data) throws {
        let destination = pluginManifestURL
        var isDirectory: ObjCBool = false
        if renderer.fileManager.fileExists(atPath: destination.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            throw CocoaError(.fileWriteNoPermission)
        }
        let temporaryURL = destination.deletingLastPathComponent()
            .appending(path: ".plugin-install-manifest-\(UUID().uuidString).tmp")
        guard renderer.fileManager.createFile(
            atPath: temporaryURL.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        _ = try renderer.fileManager.replaceItemAt(destination, withItemAt: temporaryURL)
    }

    func importLegacyInstallManifestIfNeeded() throws {
        guard !renderer.fileManager.fileExists(atPath: pluginManifestURL.path) else { return }
        let legacyURL = legacyInstallStateDirectoryURL.appending(path: "plugin-install-manifest.json")
        guard legacyURL != pluginManifestURL,
              renderer.fileManager.fileExists(atPath: legacyURL.path) else { return }

        let lock = try AgentIntegrationInstallStateLock.acquire(
            in: installStateDirectoryURL,
            fileManager: renderer.fileManager
        )
        defer { lock.release() }
        guard !renderer.fileManager.fileExists(atPath: pluginManifestURL.path) else { return }
        let data = try Data(contentsOf: legacyURL)
        guard let manifest = try? JSONDecoder().decode(AgentPluginInstallManifest.self, from: data),
              manifest.version <= AgentPluginInstallManifest.currentVersion else {
            Self.persistenceLogger.error(
                "ignoring unreadable legacy plugin manifest at \(legacyURL.path, privacy: .private)"
            )
            return
        }
        try renderer.fileManager.createDirectory(at: installStateDirectoryURL, withIntermediateDirectories: true)
        try data.write(to: pluginManifestURL, options: .atomic)
        try renderer.fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: pluginManifestURL.path
        )
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
