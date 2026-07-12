import AwesoMuxConfig
import Foundation
import os

/// The CLI-driven agent providers that ship as native plugin **marketplace
/// trees** — Claude Code, Codex, and Grok — as opposed to the single-file
/// providers (OpenCode, Pi) handled by `AgentIntegrationInstaller`.
///
/// These are deliberately kept out of `AgentIntegrationInstallProvider`: their
/// install is a provider-CLI `marketplace add` against a rendered tree, not a
/// byte-copy into a provider directory, and their status carries a trust model
/// the file installer has no concept of. The guard test
/// `settingsInstallerExcludesNativeMarketplaceProviders` pins that separation.
enum AgentPluginProvider: String, CaseIterable, Hashable, Sendable {
    case claudeCode = "claude_code"
    case codex
    case grok

    /// The bundled marketplace-root tree, relative to the resources directory.
    /// The tree root is itself the marketplace root (it carries
    /// the provider-specific marketplace manifest).
    var bundledTreeRelativePath: String {
        switch self {
        case .claudeCode:
            "AgentIntegrations/claude_code"
        case .codex:
            "AgentIntegrations/codex"
        case .grok:
            "AgentIntegrations/grok"
        }
    }

    /// Files within the tree whose helper-path placeholder must be baked at
    /// render time. Only the hook config references the helper; the marketplace
    /// and plugin manifests are static and copied verbatim.
    var helperPathFileRelativePaths: [String] {
        switch self {
        case .claudeCode:
            ["plugins/awesomux-claude-status/hooks/hooks.json"]
        case .codex:
            ["plugins/awesomux-codex-status/hooks/hooks.json"]
        case .grok:
            ["plugins/awesomux-grok-status/hooks/hooks.json"]
        }
    }
}

/// The product of rendering a plugin marketplace tree: the marketplace root the
/// provider CLI is later pointed at (P4), and the hook configs whose helper path
/// was baked in.
struct AgentPluginRenderedTree: Equatable, Sendable {
    var provider: AgentPluginProvider
    var marketplaceRootURL: URL
    var hookConfigURLs: [URL]
    var helperPath: String
}

enum AgentPluginTemplateRendererError: Error, Equatable, Sendable {
    case providerDisabled(AgentPluginProvider)
    case missingTemplateTree(URL)
    case missingHelperPathFile(URL)
    case helperPathPlaceholderMissing(URL)
}

/// Renders a bundled Claude Code / Codex plugin marketplace tree into Application
/// Support, baking the running bundle's `awesoMuxAgentHook` path into the hook
/// config. The rendered root is the artifact the provider CLI installs from in a
/// later slice; this type does no CLI work and writes nothing outside the
/// awesoMux-owned support directory.
/// `@unchecked Sendable`: the only non-`Sendable` stored property is
/// `FileManager`, whose `.default` instance is documented thread-safe for the
/// read/copy/attribute operations the renderer performs.
struct AgentPluginTemplateRenderer: @unchecked Sendable {
    private static let logger = Logger(
        subsystem: "com.interactivebuffoonery.awesomux",
        category: "AgentPluginTemplateRenderer"
    )

    /// The hook command default the bundled templates ship. Rendering replaces
    /// the assignment fallback with the resolved absolute path, leaving the
    /// `AWESOMUX_AGENT_HOOK` override intact so a test or alternate-bundle
    /// scenario can still point the hook elsewhere.
    static let helperPlaceholderToken = "AWESOMUX_AGENT_HOOK=${AWESOMUX_AGENT_HOOK:-awesoMuxAgentHook};"

    var resourcesDirectoryURL: URL
    var supportDirectoryURL: URL
    var fileManager: FileManager
    private let renderLock = NSLock()

    init(
        resourcesDirectoryURL: URL = Bundle.main.resourceURL ?? Bundle.main.bundleURL,
        supportDirectoryURL: URL = SessionPersistence.supportDirectoryURL,
        fileManager: FileManager = .default
    ) {
        self.resourcesDirectoryURL = resourcesDirectoryURL
        self.supportDirectoryURL = supportDirectoryURL
        self.fileManager = fileManager
    }

    var rootDirectoryURL: URL {
        supportDirectoryURL.appending(path: "AgentIntegrations", directoryHint: .isDirectory)
    }

    func bundledTreeURL(provider: AgentPluginProvider) -> URL {
        resourcesDirectoryURL.appending(path: provider.bundledTreeRelativePath, directoryHint: .isDirectory)
    }

    /// The rendered marketplace root for a provider. Keyed by provider alone: the
    /// rendered tree's content depends only on the bundle-derived helper path,
    /// which is identical across setups, so a provider has one rendered tree
    /// regardless of its configured binary path or config home.
    func renderedTreeURL(provider: AgentPluginProvider) -> URL {
        rootDirectoryURL
            .appending(path: "rendered", directoryHint: .isDirectory)
            .appending(path: provider.rawValue, directoryHint: .isDirectory)
    }

    func render(
        provider: AgentPluginProvider,
        setup: AgentIntegrationSetup,
        helperPath: AgentHookHelperPath
    ) throws -> AgentPluginRenderedTree {
        renderLock.lock()
        defer { renderLock.unlock() }

        guard setup.enabled else {
            throw AgentPluginTemplateRendererError.providerDisabled(provider)
        }

        let bundledTreeURL = bundledTreeURL(provider: provider)
        guard fileManager.fileExists(atPath: bundledTreeURL.path) else {
            throw AgentPluginTemplateRendererError.missingTemplateTree(bundledTreeURL)
        }

        if helperPath.isDevelopmentBundle {
            Self.logger.warning(
                "baking a dist/ development hook path for \(provider.rawValue, privacy: .public); the install breaks if that build folder is removed: \(helperPath.path, privacy: .public)"
            )
        }

        let renderedTreeURL = renderedTreeURL(provider: provider)
        try createPrivateDirectory(renderedTreeURL.deletingLastPathComponent())
        // Clean re-render of awesoMux's generated cache: a stale tree from a
        // prior bundle path must not leave an orphaned hook config behind the
        // freshly baked one. Provider-installed copies are handled later by the
        // manifest-aware install/uninstall service.
        if fileManager.fileExists(atPath: renderedTreeURL.path) {
            try fileManager.removeItem(at: renderedTreeURL)
        }
        try fileManager.copyItem(at: bundledTreeURL, to: renderedTreeURL)
        setPrivatePermissions(0o700, on: renderedTreeURL)

        var hookConfigURLs: [URL] = []
        for relativePath in provider.helperPathFileRelativePaths {
            let hookURL = renderedTreeURL.appending(path: relativePath)
            guard fileManager.fileExists(atPath: hookURL.path) else {
                throw AgentPluginTemplateRendererError.missingHelperPathFile(hookURL)
            }
            try bakeHelperPath(into: hookURL, helperPath: helperPath.path)
            hookConfigURLs.append(hookURL)
        }

        return AgentPluginRenderedTree(
            provider: provider,
            marketplaceRootURL: renderedTreeURL,
            hookConfigURLs: hookConfigURLs,
            helperPath: helperPath.path
        )
    }

    private func bakeHelperPath(into fileURL: URL, helperPath: String) throws {
        let original = try String(contentsOf: fileURL, encoding: .utf8)
        guard original.contains(Self.helperPlaceholderToken) else {
            throw AgentPluginTemplateRendererError.helperPathPlaceholderMissing(fileURL)
        }
        let baked = original.replacingOccurrences(
            of: Self.helperPlaceholderToken,
            with: try jsonEscapedStringContents(
                "AWESOMUX_AGENT_HOOK=${AWESOMUX_AGENT_HOOK:-\(shellSingleQuoted(helperPath))};"
            )
        )
        try writePrivateFile(Data(baked.utf8), to: fileURL)
    }

    private func shellSingleQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func jsonEscapedStringContents(_ value: String) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let encoded = try encoder.encode(value)
        let string = String(decoding: encoded, as: UTF8.self)
        return String(string.dropFirst().dropLast())
    }

    private func createPrivateDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw AgentPluginTemplateRendererError.missingTemplateTree(url)
            }
            setPrivatePermissions(0o700, on: url)
        } else {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            setPrivatePermissions(0o700, on: url)
        }
    }

    private func writePrivateFile(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic])
        setPrivatePermissions(0o600, on: url)
    }

    private func setPrivatePermissions(_ permissions: Int, on url: URL) {
        do {
            try fileManager.setAttributes(
                [.posixPermissions: permissions],
                ofItemAtPath: url.path
            )
        } catch {
            Self.logger.error(
                "failed to set private permissions on \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
