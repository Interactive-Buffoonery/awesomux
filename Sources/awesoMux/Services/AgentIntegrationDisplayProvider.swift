import Foundation

/// The set of agent integrations shown in settings, ordered for display.
///
/// OpenCode and Pi are backed by a real `AgentIntegrationInstallProvider`
/// (file-drop installs). Claude Code, Codex, and Grok are backed by
/// `AgentPluginProvider` (CLI-driven installs via the `AgentPluginRunner`). This
/// is the seam between the settings surface and the two install machineries: a
/// case routes to exactly one of `installable` or `pluginProvider`.
enum AgentIntegrationDisplayProvider: CaseIterable, Hashable, Sendable {
    case claudeCode
    case codex
    case openCode
    case pi
    case grok

    init(_ installable: AgentIntegrationInstallProvider) {
        switch installable {
        case .openCode:
            self = .openCode
        case .pi:
            self = .pi
        }
    }

    init(_ pluginProvider: AgentPluginProvider) {
        switch pluginProvider {
        case .claudeCode:
            self = .claudeCode
        case .codex:
            self = .codex
        case .grok:
            self = .grok
        }
    }

    /// The file-drop install provider, or `nil` for the CLI-driven providers.
    var installable: AgentIntegrationInstallProvider? {
        switch self {
        case .openCode:
            .openCode
        case .pi:
            .pi
        case .claudeCode, .codex, .grok:
            nil
        }
    }

    /// The CLI-driven plugin provider, or `nil` for the file-drop providers.
    var pluginProvider: AgentPluginProvider? {
        switch self {
        case .openCode, .pi:
            nil
        case .claudeCode:
            .claudeCode
        case .codex:
            .codex
        case .grok:
            .grok
        }
    }
}
