import Foundation

public enum AgentKind: String, CaseIterable, Codable, Hashable, Sendable {
    case claudeCode = "Claude Code"
    case codex = "Codex"
    case openCode = "OpenCode"
    case pi = "Pi"
    case grok = "Grok"
    case shell = "Shell"

    public var shortName: String {
        localizedShortName()
    }

    public func localizedShortName(
        bundle: Bundle = .main,
        locale: Locale = .current
    ) -> String {
        switch self {
        case .claudeCode:
            "Claude"
        case .codex:
            "Codex"
        case .openCode:
            "OpenCode"
        case .pi:
            "Pi"
        case .grok:
            "Grok"
        case .shell:
            // Unlike the brand-name cases above, "Shell" is a generic noun that
            // sits next to SessionStoreText's localized "shell" fallback prefix
            // in the same spoken VoiceOver utterance (e.g. rotor/row labels) —
            // leaving it hardcoded would create a mixed-language announcement
            // once a catalog exists (INT-95 review finding).
            String(
                localized: "Shell",
                bundle: bundle,
                locale: locale,
                comment: "Generic agent-kind display name for a plain shell session (not an AI agent brand name)"
            )
        }
    }

    /// Full display name for spoken/announcement contexts (e.g. VoiceOver attention
    /// announcements): `rawValue`'s full brand name ("Claude Code") for agent kinds,
    /// but `shortName`'s localized text for `.shell` — `rawValue`'s "Shell" is the
    /// Codable/persistence representation and must stay a fixed literal, so callers
    /// that speak this value out loud need this instead (INT-95 PR-review finding:
    /// `WorkspaceAttentionAnnouncementTracker` was reading raw `rawValue` and could
    /// speak an unlocalized "Shell" beside an already-localized workspace title).
    public var spokenName: String {
        localizedSpokenName()
    }

    public func localizedSpokenName(
        bundle: Bundle = .main,
        locale: Locale = .current
    ) -> String {
        self == .shell ? localizedShortName(bundle: bundle, locale: locale) : rawValue
    }

    public var initialSessionState: AgentState {
        switch self {
        case .claudeCode, .codex, .openCode, .pi, .grok:
            .running
        case .shell:
            .idle
        }
    }

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
