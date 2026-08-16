import AwesoMuxBridgeProtocol
import AwesoMuxConfig
import Foundation

/// Where a provider CLI keeps its per-user state — `CLAUDE_CONFIG_DIR` /
/// `CODEX_HOME`, or the integration's `config_home` override.
///
/// Lifted out of `ProcessAgentPluginRunner`'s `claudeConfigHome` / `codexHome`,
/// which now delegate here. It moved because a second copy appeared the moment
/// something outside plugin installation needed the answer: an operator who
/// points `config_home` at a non-default directory installs the hook there, so
/// the transcript that hook's session writes is there too, and a resolver that
/// disagreed with the installer would look for it in `~`.
enum AgentConfigHome {
    /// - Returns: `nil` for a kind with no known config home. `.shell` has
    ///   none, and the remaining providers have not been mapped because nothing
    ///   reads their config home yet — an unmapped kind must not silently
    ///   resolve to some other provider's directory.
    static func url(
        for kind: AgentKind,
        setup: AgentIntegrationSetup,
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL? {
        guard let defaultDirectoryName = defaultDirectoryName(for: kind) else { return nil }
        return url(
            setup: setup,
            defaultDirectoryName: defaultDirectoryName,
            homeDirectoryURL: homeDirectoryURL
        )
    }

    static func url(
        setup: AgentIntegrationSetup,
        defaultDirectoryName: String,
        homeDirectoryURL: URL
    ) -> URL {
        if let configHome = setup.configHome?.trimmingCharacters(in: .whitespacesAndNewlines),
            !configHome.isEmpty
        {
            return URL(fileURLWithPath: (configHome as NSString).expandingTildeInPath)
        }
        return homeDirectoryURL.appending(path: defaultDirectoryName, directoryHint: .isDirectory)
    }

    /// Every kind `url(for:setup:)` can answer for, in a stable order.
    ///
    /// Derived from the switch below rather than restated, so a provider
    /// gaining a config home is picked up by the callers that sweep them
    /// without a second list to remember.
    static var kindsWithConfigHome: [AgentKind] {
        AgentKind.allCases.filter { defaultDirectoryName(for: $0) != nil }
    }

    private static func defaultDirectoryName(for kind: AgentKind) -> String? {
        switch kind {
        case .claudeCode: ".claude"
        case .codex: ".codex"
        case .openCode, .pi, .grok, .shell: nil
        }
    }

    /// The integration settings for one kind, so callers do not each re-write
    /// the same six-case switch over `AgentIntegrationsConfig`.
    static func setup(
        for kind: AgentKind,
        in integrations: AgentIntegrationsConfig
    ) -> AgentIntegrationSetup {
        switch kind {
        case .claudeCode: integrations.claudeCode
        case .codex: integrations.codex
        case .openCode: integrations.openCode
        case .pi: integrations.pi
        case .grok: integrations.grok
        case .shell: .defaultValue
        }
    }
}
