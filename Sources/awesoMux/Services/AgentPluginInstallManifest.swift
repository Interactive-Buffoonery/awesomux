import Foundation

// MARK: - AgentPluginMarketplaceRef

/// The marketplace + plugin identity the provider CLIs key on, derived from the
/// rendered `marketplace.json` rather than hardcoded. The marketplace name is the
/// manifest's top-level `name`; the plugin name is `plugins[0].name`. The install
/// ref the provider CLIs consume is `<plugin>@<marketplace>` (decision 6,
/// Context7-confirmed: e.g. `awesomux-runtime-status@awesomux-claude`).
struct AgentPluginMarketplaceRef: Equatable, Sendable {
    var marketplaceName: String
    var pluginName: String

    /// `<plugin>@<marketplace>` — the ref `claude plugin install` /
    /// `codex plugin add` and `claude plugin list --json` / Codex `hooks/list`
    /// (`pluginId`) all key on.
    var pluginRef: String {
        "\(pluginName)@\(marketplaceName)"
    }

    /// Reads the marketplace + first-plugin name out of a rendered marketplace
    /// tree. Claude and Codex carry `.claude-plugin/marketplace.json`; Grok carries
    /// `.grok-plugin/marketplace.json`.
    static func read(
        fromRenderedTreeAt rootURL: URL,
        fileManager: FileManager = .default
    ) throws -> AgentPluginMarketplaceRef {
        let claudeManifestURL = rootURL.appending(path: ".claude-plugin/marketplace.json")
        let grokManifestURL = rootURL.appending(path: ".grok-plugin/marketplace.json")
        let manifestURL: URL
        if fileManager.fileExists(atPath: claudeManifestURL.path) {
            manifestURL = claudeManifestURL
        } else if fileManager.fileExists(atPath: grokManifestURL.path) {
            manifestURL = grokManifestURL
        } else {
            throw AgentPluginMarketplaceRefError.missingMarketplaceManifest(rootURL)
        }
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(MarketplaceManifest.self, from: data)
        guard let plugin = manifest.plugins.first else {
            throw AgentPluginMarketplaceRefError.emptyMarketplaceManifest(manifestURL)
        }
        return AgentPluginMarketplaceRef(
            marketplaceName: manifest.name,
            pluginName: plugin.name
        )
    }

    private struct MarketplaceManifest: Decodable {
        let name: String
        let plugins: [Plugin]

        struct Plugin: Decodable {
            let name: String
        }
    }
}

enum AgentPluginMarketplaceRefError: Error, Equatable, Sendable {
    case missingMarketplaceManifest(URL)
    case emptyMarketplaceManifest(URL)
}

// MARK: - AgentPluginInstallRecord

/// One CLI-driven provider's install record. Keyed by `AgentPluginProvider` and
/// `configHome` (one install per provider config folder), it pins the paths and refs the modified-file safety
/// invariant on uninstall/repair reads back (contract §3): the executable used,
/// the resolved config home, the rendered marketplace root, the baked helper
/// path, and the marketplace/plugin refs.
struct AgentPluginInstallRecord: Codable, Equatable, Sendable {
    var provider: AgentPluginProvider
    var binaryPath: String?
    /// Claude config home (`~/.claude`), Codex `CODEX_HOME` (`~/.codex`), or
    /// Grok config home (`~/.grok`), resolved at install time.
    var configHome: String
    var marketplaceRoot: String
    var helperPath: String
    var marketplaceName: String
    var pluginName: String
    /// Pre-bake digest of the bundled plugin source at install time (see
    /// `AgentPluginSourceFingerprint`). Optional so older install records still
    /// decode; a missing value means status cannot prove the install is current.
    var sourceContentDigest: String?

    var pluginRef: AgentPluginMarketplaceRef {
        AgentPluginMarketplaceRef(marketplaceName: marketplaceName, pluginName: pluginName)
    }
}

extension AgentPluginProvider: Codable {}

// MARK: - AgentPluginInstallManifest

/// awesoMux-owned record of the CLI-driven installs, separate from the file-drop
/// `AgentIntegrationInstallManifest` (OpenCode/Pi) so the two install machineries
/// never collide on a shared store.
struct AgentPluginInstallManifest: AgentInstallManifest, Equatable, Sendable {
    var version: Int
    var records: [AgentPluginInstallRecord]

    /// Version 2 keys records by provider and config folder. A version 1 writer
    /// keyed by provider alone and would drop every other folder's record on its
    /// next save, so version 1 builds must see this format as unsupported. Version
    /// 1 manifests still decode unchanged and are rewritten as version 2.
    static let currentVersion = 2
    static let empty = AgentPluginInstallManifest(
        version: currentVersion,
        records: []
    )

    func record(for provider: AgentPluginProvider, configHome: String) -> AgentPluginInstallRecord? {
        records.first { $0.provider == provider && Self.sameFolder($0.configHome, configHome) }
    }

    mutating func removeRecord(provider: AgentPluginProvider, configHome: String) {
        records.removeAll { $0.provider == provider && Self.sameFolder($0.configHome, configHome) }
    }

    private static func sameFolder(_ lhs: String, _ rhs: String) -> Bool {
        URL(fileURLWithPath: lhs).resolvingSymlinksInPath().path == URL(fileURLWithPath: rhs).resolvingSymlinksInPath().path
    }
}
