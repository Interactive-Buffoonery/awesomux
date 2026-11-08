import AwesoMuxBridgeProtocol
import AwesoMuxCore
import Foundation

public enum AgentHookProvider: String, Sendable {
    case claudeCode = "claude-code"
    case codex
    case openCode = "opencode"
    case pi
    case grok
    case antigravity

    var source: AgentRuntimeSource {
        switch self {
        case .claudeCode:
            .claudeCode
        case .codex:
            .codex
        case .openCode:
            .openCode
        case .pi:
            .pi
        case .grok:
            .grok
        case .antigravity:
            .antigravity
        }
    }

    var kind: AgentKind {
        switch self {
        case .claudeCode:
            .claudeCode
        case .codex:
            .codex
        case .openCode:
            .openCode
        case .pi:
            .pi
        case .grok:
            .grok
        case .antigravity:
            .antigravity
        }
    }
}
