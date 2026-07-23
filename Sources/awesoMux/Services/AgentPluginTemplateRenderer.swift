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
    /// this assignment fallback with a runtime resolution ladder (see
    /// `helperResolutionSnippet`) that survives the installing app being moved
    /// or removed, leaving the `AWESOMUX_AGENT_HOOK` override intact so a test
    /// or alternate-bundle scenario can still point the hook elsewhere.
    static let helperPlaceholderToken = "AWESOMUX_AGENT_HOOK=${AWESOMUX_AGENT_HOOK:-awesoMuxAgentHook};"

    var resourcesDirectoryURL: URL
    var supportDirectoryURL: URL
    var fileManager: FileManager
    /// Bundle identifier used to relocate a moved/reinstalled app at hook
    /// runtime via Spotlight. Defaults to the running (installing) bundle so a
    /// development or worktree build recovers to itself; falls back to the
    /// production id under a test host that has no bundle identity.
    var bundleIdentifier: String
    private let renderLock = NSLock()

    init(
        resourcesDirectoryURL: URL = Bundle.main.resourceURL ?? Bundle.main.bundleURL,
        supportDirectoryURL: URL = SessionPersistence.supportDirectoryURL,
        fileManager: FileManager = .default,
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? AppRuntimeProfile.productionBundleIdentifier
    ) {
        self.resourcesDirectoryURL = resourcesDirectoryURL
        self.supportDirectoryURL = supportDirectoryURL
        self.fileManager = fileManager
        self.bundleIdentifier = bundleIdentifier
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
        clampOwnerOnly(directoryAt: renderedTreeURL)

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
            with: try jsonEscapedStringContents(helperResolutionSnippet(helperPath: helperPath))
        )
        try writePrivateFile(Data(baked.utf8), to: fileURL)
    }

    /// Runtime resolution ladder baked in place of the shipped assignment
    /// fallback. Plugin hooks are command-type — the provider runs this string
    /// through a POSIX shell — so the fallback can no longer be one frozen path:
    /// if the app that performed the install is later moved or removed, the
    /// baked path execs a missing binary and every tool call errors (issue #164).
    /// The ladder resolves the helper at hook time instead:
    ///   1. an `AWESOMUX_AGENT_HOOK` override that still points at an executable
    ///      (awesoMux sets this per pane; the `-x` guard rejects a stale one so
    ///      a bundle deleted mid-session falls through instead of erroring),
    ///   2. the path baked at render time (the common out-of-pane case),
    ///   3. the app relocated via a Spotlight bundle-id lookup — iterated, not
    ///      `head -1`, because a lingering stale duplicate can index first and
    ///      would otherwise strand a valid moved copy behind it (the exact
    ///      "removed a stale duplicate" scenario in the issue),
    ///   4. otherwise one hint to stderr and `exit 0` — non-blocking, and
    ///      strictly safer than the shell's exec-failure 127 the issue already
    ///      tolerates.
    /// The bundle id is the installing bundle's own (trusted, `[A-Za-z0-9.-]`),
    /// so no shell metacharacters reach the single-quoted mdfind query.
    /// ponytail: the Spotlight branch re-runs on every hook invocation while the
    /// app stays moved (each provider spawns a fresh shell, nothing caches the
    /// resolved path); acceptable because it fires only on the already-degraded
    /// path and is bounded by the hook timeout. Durable fix is launch-time
    /// self-heal that rewrites the baked path — follow-up, issue #164 option 2.
    private func helperResolutionSnippet(helperPath: String) -> String {
        let quotedPath = shellSingleQuoted(helperPath)
        let name = AgentRuntimeEnvironment.hookExecutableName
        // The id is interpolated into a double-quoted mdfind argument, where a
        // stray `"`/`$`/backtick would break out or command-substitute. Bundle
        // identifiers are `[A-Za-z0-9.-]` by construction and ours comes from a
        // signed Info.plist, so this guard never fires in practice — but the
        // value is baked into a command that runs on every hook, so a
        // metacharacter must fall back to the known-safe id rather than reach
        // the shell.
        let query =
            Self.isShellSafeBundleIdentifier(bundleIdentifier)
            ? bundleIdentifier
            : AppRuntimeProfile.productionBundleIdentifier
        return """
            if [ -n "$AWESOMUX_AGENT_HOOK" ] && [ -x "$AWESOMUX_AGENT_HOOK" ]; then :; \
            elif [ -x \(quotedPath) ]; then AWESOMUX_AGENT_HOOK=\(quotedPath); \
            else AWESOMUX_AGENT_HOOK="$(mdfind "kMDItemCFBundleIdentifier == '\(query)'" 2>/dev/null | while IFS= read -r app; do if [ -x "$app/Contents/MacOS/\(name)" ]; then printf '%s' "$app/Contents/MacOS/\(name)"; break; fi; done)"; \
            if [ -z "$AWESOMUX_AGENT_HOOK" ]; then echo "awesoMux agent hook not found (moved or removed?); reinstall the awesoMux agent integration from Settings." >&2; exit 0; fi; \
            fi;
            """
    }

    private func shellSingleQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    /// A bundle identifier safe to interpolate into the mdfind shell query: the
    /// CFBundleIdentifier-legal alphabet with no shell-active characters.
    static func isShellSafeBundleIdentifier(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.allSatisfy { byte in
                (byte >= 0x41 && byte <= 0x5A)  // A-Z
                    || (byte >= 0x61 && byte <= 0x7A)  // a-z
                    || (byte >= 0x30 && byte <= 0x39)  // 0-9
                    || byte == 0x2E  // .
                    || byte == 0x2D  // -
            }
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
            clampOwnerOnly(directoryAt: url)
        } else {
            try fileManager.createOwnerOnlyDirectory(at: url)
        }
    }

    private func writePrivateFile(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic])
        do {
            try fileManager.setOwnerOnlyPermissions(onFileAt: url)
        } catch {
            Self.logger.error(
                "failed to set private permissions on \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func clampOwnerOnly(directoryAt url: URL) {
        do {
            try fileManager.setOwnerOnlyPermissions(onDirectoryAt: url)
        } catch {
            Self.logger.error(
                "failed to set private permissions on \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
