import CryptoKit
import Foundation

/// Digests the **pre-bake** bundled plugin source for Claude / Codex / Grok so
/// status can tell when a newer awesoMux ships different hooks than the user
/// last installed.
///
/// The digest intentionally ignores the baked helper *path* (it changes when the
/// app moves or a `dist/` build is used), but it does fold in the render-format
/// *version* (`AgentPluginTemplateRenderer.renderFormatVersion`): the event names
/// and command skeleton are what actually break status when they drift, and the
/// command skeleton is produced by the renderer, not the bundled bytes. Folding
/// the version in means a change to how the command is rendered re-delivers to
/// existing installs even though the bundled `hooks.json` is byte-identical.
/// `AWESOMUX_AGENT_HOOK` still overrides the fallback at runtime either way.
enum AgentPluginSourceFingerprint {
    /// Process-lifetime cache: bundled plugin source is immutable for a running
    /// app (tests inject alternate resource roots via the cache key).
    /// Locked access; `nonisolated(unsafe)` satisfies Swift 6 global-mutable rules.
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var digestCache: [String: String] = [:]

    /// Stable hex digest of the provider's bundled content files, or `nil` when
    /// the tree is incomplete (tests / missing resources).
    static func digest(
        provider: AgentPluginProvider,
        resourcesDirectoryURL: URL,
        fileManager: FileManager = .default,
        renderFormatVersion: String = AgentPluginTemplateRenderer.renderFormatVersion
    ) -> String? {
        let cacheKey = "\(provider.rawValue)\u{1F}\(resourcesDirectoryURL.path)\u{1F}\(renderFormatVersion)"
        cacheLock.lock()
        if let cached = digestCache[cacheKey] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        guard
            let computed = computeDigest(
                provider: provider,
                resourcesDirectoryURL: resourcesDirectoryURL,
                fileManager: fileManager,
                renderFormatVersion: renderFormatVersion
            )
        else {
            return nil
        }

        cacheLock.lock()
        digestCache[cacheKey] = computed
        cacheLock.unlock()
        return computed
    }

    /// Test hook: drop cached digests so temp resource trees recompute.
    static func resetDigestCacheForTests() {
        cacheLock.lock()
        digestCache.removeAll()
        cacheLock.unlock()
    }

    private static func computeDigest(
        provider: AgentPluginProvider,
        resourcesDirectoryURL: URL,
        fileManager: FileManager,
        renderFormatVersion: String
    ) -> String? {
        let root =
            resourcesDirectoryURL
            .appending(path: provider.bundledTreeRelativePath, directoryHint: .isDirectory)
        var hasher = SHA256()
        // Fold in the render-format version so a change to the baked command
        // shape (bundled bytes unchanged) still shifts the digest and re-delivers
        // to existing installs. See AgentPluginTemplateRenderer.renderFormatVersion.
        hasher.update(data: Data("render-format\u{1F}\(renderFormatVersion)".utf8))
        hasher.update(data: Data([0]))
        var hashedAnyFile = false

        for relativePath in contentRelativePaths(for: provider).sorted() {
            let url = root.appending(path: relativePath)
            guard fileManager.fileExists(atPath: url.path),
                let data = try? Data(contentsOf: url)
            else {
                return nil
            }
            hashedAnyFile = true
            // Path prefix keeps two files with identical bodies from colliding.
            hasher.update(data: Data(relativePath.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: data)
            hasher.update(data: Data([0]))
        }

        guard hashedAnyFile else { return nil }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Bundled files that define plugin behavior for a provider. Keep in sync
    /// with the trees under `Resources/AgentIntegrations/{claude_code,codex,grok}`.
    static func contentRelativePaths(for provider: AgentPluginProvider) -> [String] {
        switch provider {
        case .claudeCode:
            [
                "plugins/awesomux-claude-status/hooks/hooks.json",
                "plugins/awesomux-claude-status/.claude-plugin/plugin.json",
            ]
        case .codex:
            [
                "plugins/awesomux-codex-status/hooks/hooks.json",
                "plugins/awesomux-codex-status/.codex-plugin/plugin.json",
            ]
        case .grok:
            [
                "plugins/awesomux-grok-status/hooks/hooks.json",
                "plugins/awesomux-grok-status/.grok-plugin/plugin.json",
            ]
        }
    }

    /// Shared Settings copy when the recorded install no longer matches the
    /// bundled source the running app would install.
    static let outdatedInstallGuidance =
        "A newer awesoMux status plugin is available. Repair to update, then restart open sessions so they load it"

    /// Installs recorded before awesoMux started storing content digests cannot
    /// prove freshness. One Repair records a digest and picks up any hook fixes
    /// shipped since the original install.
    static let legacyInstallMissingDigestGuidance =
        "Repair once to refresh this status plugin and enable automatic update alerts when awesoMux ships new hooks"
}
