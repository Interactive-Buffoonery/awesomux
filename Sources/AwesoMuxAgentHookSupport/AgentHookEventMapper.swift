import Foundation
import AwesoMuxCore

public enum AgentHookEventMapper {
    public static func event(
        provider: AgentHookProvider,
        hookEventName: String,
        notificationType: String? = nil,
        providerSessionID: String? = nil,
        reason: String? = nil,
        eventID: String = UUID().uuidString,
        timestamp: Date = Date()
    ) -> AgentRuntimeEvent? {
        guard let mapping = mapping(
            provider: provider,
            hookEventName: hookEventName,
            notificationType: notificationType,
            reason: reason
        ) else {
            return nil
        }

        return AgentRuntimeEvent(
            source: provider.source,
            kind: provider.kind,
            executionState: mapping.executionState,
            attentionReason: mapping.attentionReason,
            phase: mapping.phase,
            eventID: eventID,
            providerSessionID: providerSessionID,
            timestamp: timestamp
        )
    }

    private static func mapping(
        provider: AgentHookProvider,
        hookEventName: String,
        notificationType: String?,
        reason: String?
    ) -> EventMapping? {
        switch provider {
        case .claudeCode:
            claudeCodeMapping(hookEventName: hookEventName, notificationType: notificationType)
        case .codex, .openCode, .pi:
            // Codex shares the local-agent map so its SessionEnd resets the tile
            // (agent gone, not a turn-end .waiting) the same way OpenCode/Pi do.
            // Without this a quit Codex session left a stuck glyph/state — the
            // passive idle-shell detector was its only, lossy, reset path.
            localAgentMapping[hookEventName]
        case .grok:
            grokMapping(hookEventName: hookEventName, reason: reason)
        }
    }

    private static func claudeCodeMapping(
        hookEventName: String,
        notificationType: String?
    ) -> EventMapping? {
        switch hookEventName {
        case "Notification":
            claudeCodeNotificationMapping(notificationType: notificationType)
        case "StopFailure":
            EventMapping(executionState: .error, phase: .stop)
        case "SessionEnd":
            EventMapping(executionState: .idle, phase: .sessionEnd)
        default:
            baseMapping[hookEventName]
        }
    }

    private static func claudeCodeNotificationMapping(notificationType: String?) -> EventMapping {
        switch notificationType {
        case "permission_prompt":
            EventMapping(attentionReason: .permissionPrompt, phase: .notification)
        case "idle_prompt":
            EventMapping(executionState: .waiting, phase: .notification)
        default:
            EventMapping(attentionReason: .userInputRequired, phase: .notification)
        }
    }

    private static func grokMapping(hookEventName: String, reason: String?) -> EventMapping? {
        switch hookEventName {
        case "SessionStart", "session_start":
            baseMapping["SessionStart"]
        case "UserPromptSubmit", "user_prompt_submit":
            baseMapping["UserPromptSubmit"]
        case "PreToolUse", "pre_tool_use":
            baseMapping["PreToolUse"]
        case "PostToolUse", "post_tool_use":
            baseMapping["PostToolUse"]
        case "SubagentStart", "subagent_start":
            baseMapping["SubagentStart"]
        case "SubagentStop", "subagent_stop":
            baseMapping["SubagentStop"]
        case "PermissionDenied", "permission_denied":
            EventMapping(executionState: .error, phase: .notification)
        case "Notification", "notification":
            EventMapping(attentionReason: .userInputRequired, phase: .notification)
        case "Stop":
            baseMapping["Stop"]
        case "stop":
            grokLegacyStopMapping(reason: reason)
        case "SessionEnd", "session_end":
            localAgentMapping["SessionEnd"]
        case "stop_failure", "StopFailure":
            localAgentMapping["StopFailure"]
        default:
            nil
        }
    }

    private static func grokLegacyStopMapping(reason: String?) -> EventMapping {
        switch reason?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "end_turn":
            EventMapping(executionState: .waiting, phase: .stop)
        case nil, "", "shutdown",
             "cancel", "cancelled", "canceled", "abort", "aborted",
             "error", "failed", "failure":
            EventMapping(executionState: .error, phase: .stop)
        default:
            EventMapping(executionState: .error, phase: .stop)
        }
    }

    // The execution rows every provider shares. Single source of truth; per-provider
    // deltas (StopFailure, Notification) are layered on top so these rows cannot drift.
    private static let baseMapping: [String: EventMapping] = [
        "SessionStart": EventMapping(executionState: .idle, phase: .sessionStart),
        "UserPromptSubmit": EventMapping(executionState: .thinking, phase: .promptSubmit),
        "PreToolUse": EventMapping(executionState: .thinking, phase: .toolStart),
        "PostToolUse": EventMapping(executionState: .thinking, phase: .toolEnd),
        "SubagentStart": EventMapping(executionState: .thinking, phase: .toolStart),
        "SubagentStop": EventMapping(executionState: .thinking, phase: .toolEnd),
        "PermissionRequest": EventMapping(
            attentionReason: .permissionPrompt,
            phase: .notification
        ),
        // Turn-end rests directly on the quiet waiting state: the blue pause is
        // the primary "waiting on your next turn" semantic. Unfocused Stop
        // events still get unread/notification handling in Core, but they do not
        // project to the peach attention badge unless a provider reports a real
        // blocking prompt such as PermissionRequest.
        "Stop": EventMapping(
            executionState: .waiting,
            phase: .stop
        ),
    ]

    // OpenCode/Pi add StopFailure and a flat-userInputRequired Notification: unlike Claude
    // Code these providers do not forward notification subtypes, so the event carries no
    // subtype to switch on. The additive keys never overlap base, so the combine never fires.
    private static let localAgentMapping: [String: EventMapping] = baseMapping.merging([
        "Notification": EventMapping(
            attentionReason: .userInputRequired,
            phase: .notification
        ),
        // Session exit is distinct from turn-end: the agent is gone, not waiting
        // for input. Unlike Stop this carries no attentionReason, and its
        // .sessionEnd phase tells the reducer to fully reset the tile (clear
        // attention/unread, drop the agent kind back to shell) so a quit agent
        // does not leave a stuck peach badge or a lingering agent glyph.
        "SessionEnd": EventMapping(executionState: .idle, phase: .sessionEnd),
        "StopFailure": EventMapping(executionState: .error, phase: .stop)
    ]) { _, new in new }

    private struct EventMapping {
        var executionState: AgentExecutionState?
        var attentionReason: AttentionReason?
        var phase: AgentRuntimePhase
    }
}
