import AwesoMuxBridgeProtocol
import Foundation
import UnicodeHygiene

enum SessionStoreText: Sendable {
    static let maxTitleLength = BridgeMessage.FieldLimit.title
    static let maxGroupNameLength = 80
    static let canonicalDefaultGroupName = "awesoMux"

    static func sanitizedTitle(_ rawTitle: String) -> String {
        UnicodeHygiene.sanitize(rawTitle, maxLength: maxTitleLength)
    }

    static func sanitizedGroupName(_ rawName: String) -> String {
        UnicodeHygiene.sanitize(rawName, maxLength: maxGroupNameLength, stripInvisibleRoutingScalars: true)
    }

    static func groupLookupKey(_ rawName: String) -> String {
        // Mixed-script confusable names divert to the canonical default the
        // same way invisible names do: routing must never mint a group whose
        // name the create/rename sheets would refuse (INT-485).
        guard !UnicodeHygiene.hasSuspiciousScriptMixing(rawName) else {
            return canonicalDefaultGroupName
        }

        let sanitised = sanitizedGroupName(rawName)
        return sanitised.isEmpty ? canonicalDefaultGroupName : sanitised
    }

    static func restoredTitle(_ rawTitle: String) -> String {
        restoredTitle(rawTitle, fallbackForAgent: .shell, index: 1)
    }

    static func restoredTitle(
        _ rawTitle: String,
        fallbackForAgent agentKind: AgentKind,
        index: Int
    ) -> String {
        let title = sanitizedTitle(rawTitle)
        guard title.isEmpty else {
            return title
        }

        return syntheticSessionTitle(for: agentKind, index: index)
    }

    /// Composes a synthetic fallback session title (e.g. "shell 1"). The only
    /// place `restoredTitle`, `defaultGroups`, and `WorkspaceTreeReducer.nextSessionTitle`
    /// assemble a fallback title, so the prefix+index shape and its translator
    /// comment exist in one spot instead of drifting across three copies.
    static func syntheticSessionTitle(for agentKind: AgentKind, index: Int) -> String {
        SyntheticSessionTitle(agentKind: agentKind, index: index).localizedTitle()
    }

    /// Prefix for a synthetic fallback session title (e.g. "shell 1"). Only the
    /// generic "shell" noun is localized — other agent kinds fall back to their
    /// brand name (`AgentKind.shortName`), which stays untranslated like the
    /// "awesoMux" default group name above.
    static func syntheticSessionTitlePrefix(for agentKind: AgentKind) -> String {
        guard agentKind == .shell else {
            return agentKind.shortName
        }
        return String(
            localized: "shell",
            bundle: .main,
            locale: .current,
            comment: "Fallback session title prefix for an unnamed shell session, e.g. \"shell 1\""
        )
    }

    /// True when `rawTitle` sanitizes to empty — i.e. `restoredTitle` would
    /// substitute a synthetic `"<agent> <index>"` fallback. A caller restoring a
    /// pane's `isTitleUserEdited` freeze must clear it in this case: the pane
    /// would otherwise come back frozen on a synthetic name the user never chose,
    /// with the live OSC title locked out (INT-283 / QA H1).
    static func titleSanitizesToFallback(_ rawTitle: String) -> Bool {
        sanitizedTitle(rawTitle).isEmpty
    }
}

public extension SessionStore {
    nonisolated static let maxTitleLength = SessionStoreText.maxTitleLength
    nonisolated static let maxGroupNameLength = SessionStoreText.maxGroupNameLength
    nonisolated static let canonicalDefaultGroupName = SessionStoreText.canonicalDefaultGroupName

    nonisolated static func sanitizedTitle(_ rawTitle: String) -> String {
        SessionStoreText.sanitizedTitle(rawTitle)
    }

    nonisolated static func sanitizedGroupName(_ rawName: String) -> String {
        SessionStoreText.sanitizedGroupName(rawName)
    }

    nonisolated static func groupLookupKey(_ rawName: String) -> String {
        SessionStoreText.groupLookupKey(rawName)
    }

    nonisolated static func restoredTitle(_ rawTitle: String) -> String {
        SessionStoreText.restoredTitle(rawTitle)
    }

    nonisolated static func restoredTitle(
        _ rawTitle: String,
        fallbackForAgent agentKind: AgentKind,
        index: Int
    ) -> String {
        SessionStoreText.restoredTitle(
            rawTitle,
            fallbackForAgent: agentKind,
            index: index
        )
    }

    nonisolated static let previewGroups: [SessionGroup] = [
        SessionGroup(
            name: "awesoMux",
            sessions: [
                TerminalSession(
                    title: "app shell",
                    workingDirectory: "~/Development/awesomux",
                    agentKind: .claudeCode,
                    agentState: .running
                ),
                TerminalSession(
                    title: "libghostty spike",
                    workingDirectory: "~/Development/awesomux/vendor",
                    agentKind: .shell,
                    agentState: .idle
                )
            ]
        ),
        SessionGroup(
            name: "scratch",
            sessions: [
                TerminalSession(
                    title: "agent follow-up",
                    workingDirectory: "~/Desktop",
                    agentKind: .codex,
                    agentState: .needsAttention,
                    unreadNotificationCount: 2
                )
            ]
        )
    ]
}
