import Foundation

public enum AgentRuntimeSource: String, Codable, Sendable {
    case claudeCode = "claude-code"
    case codex
    case openCode = "opencode"
    case pi
    case grok
    case unknown

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = AgentRuntimeSource(rawValue: rawValue) ?? .unknown
    }

    /// Maps a runtime event source to the agent kind it implies, used as a
    /// fallback when the event omits an explicit `kind`. Returns nil for
    /// sources without a corresponding AgentKind so `.shell` stays `.shell`.
    public var inferredAgentKind: AgentKind? {
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
        case .unknown:
            nil
        }
    }

    public var hasTrustworthySessionRestartBoundary: Bool {
        switch self {
        case .claudeCode, .pi:
            true
        case .codex, .openCode, .grok, .unknown:
            false
        }
    }
}

public enum AgentRuntimePhase: String, Codable, Sendable {
    case sessionStart
    case promptSubmit
    case toolStart
    case toolEnd
    case notification
    case stop
    case sessionEnd
    case rename
    case openDocument = "open-document"
}
