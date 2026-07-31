import Foundation
import AwesoMuxBridgeProtocol

extension AgentKind {
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

    /// Full brand name for visual copy that names the agent in a sentence
    /// ("Send to Claude Code", "Enable the Claude Code integration…"): the
    /// complete `rawValue` brand for agent kinds, localized text for `.shell`.
    /// Distinct from `spokenName`, which is reserved for VoiceOver/announcement
    /// contexts; visual copy must use this so the spoken variant can evolve for
    /// speech without dragging UI strings along.
    public var displayName: String {
        localizedDisplayName()
    }

    public func localizedDisplayName(
        bundle: Bundle = .main,
        locale: Locale = .current
    ) -> String {
        self == .shell ? localizedShortName(bundle: bundle, locale: locale) : rawValue
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
}
