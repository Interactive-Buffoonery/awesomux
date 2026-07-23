import Foundation

public enum AgentKind: String, CaseIterable, Codable, Hashable, Sendable {
    case claudeCode = "Claude Code"
    case codex = "Codex"
    case openCode = "OpenCode"
    case pi = "Pi"
    case grok = "Grok"
    case shell = "Shell"

    /// Whether this kind reports its own lifecycle through the runtime-event
    /// hook side channel. When true, the hook stream is the authoritative state
    /// source and the visible-text scraper must not override it with a scraped
    /// terminal state (a subagent's transcript line reading "task complete"
    /// would otherwise flip the still-working parent to `.done`).
    public var usesReliableHooks: Bool {
        switch self {
        case .claudeCode, .codex, .openCode, .pi, .grok:
            true
        case .shell:
            false
        }
    }

    /// Whether this kind's installed integration reports blocking attention
    /// through the runtime-event side channel. Pi currently reports lifecycle
    /// events only, so visible-text attention remains its fallback. Grok Build
    /// 0.2.x never invokes plugin Permission/Notification hooks either, so it
    /// stays on the scrape path with Pi until that runtime gap closes.
    public var usesReliableAttentionHooks: Bool {
        switch self {
        case .claudeCode, .codex, .openCode:
            true
        case .pi, .grok, .shell:
            false
        }
    }
}
