import AwesoMuxBridgeProtocol
import Foundation
import Testing
@testable import AwesoMuxAgentHookSupport
@testable import AwesoMuxCore

@Suite
struct AgentHookEventMapperTests {

    @Test("Stop is turn-end waiting without attention overlay")
    func claudeCodeStopMapsDirectlyToWaiting() throws {
        let event = try #require(AgentHookEventMapper.event(
            provider: .claudeCode,
            hookEventName: "Stop"
        ))

        #expect(event.executionState == .waiting)
        #expect(event.attentionReason == nil)
        #expect(event.phase == .stop)
        // Turn-end now renders as the blue pause immediately; unread/notification
        // handling for unfocused stops is owned by Core rather than by a peach
        // needs-attention overlay.
        let displayState = AgentDisplayState(
            executionState: try #require(event.executionState),
            attentionReason: event.attentionReason
        )
        #expect(displayState == .waiting)
    }

    @Test(arguments: [
        ("PermissionRequest", Optional<String>.none, AttentionReason.permissionPrompt),
        ("Notification", Optional("permission_prompt"), AttentionReason.permissionPrompt),
        ("Notification", Optional<String>.none, AttentionReason.userInputRequired),
        ("Notification", Optional("unknown_type"), AttentionReason.userInputRequired)
    ])
    func claudeCodeAttentionEventsOmitExecution(
        hookEventName: String,
        notificationType: String?,
        attentionReason: AttentionReason
    ) throws {
        let event = try #require(AgentHookEventMapper.event(
            provider: .claudeCode,
            hookEventName: hookEventName,
            notificationType: notificationType
        ))

        #expect(event.source == .claudeCode)
        #expect(event.kind == .claudeCode)
        #expect(event.executionState == nil)
        #expect(event.attentionReason == attentionReason)
        #expect(event.phase == .notification)
    }

    @Test
    func claudeCodeIdlePromptNotificationMapsToWaiting() throws {
        let event = try #require(AgentHookEventMapper.event(
            provider: .claudeCode,
            hookEventName: "Notification",
            notificationType: "idle_prompt"
        ))

        #expect(event.executionState == .waiting)
        #expect(event.attentionReason == nil)
        #expect(event.phase == .notification)
    }

    @Test(arguments: [
        (AgentHookProvider.claudeCode, "UnknownEvent"),
        (.codex, "PreCompact"), (.codex, "PostCompact"), (.codex, "UnknownEvent"), (.codex, "PermissionReplied"),
        (.grok, "PreCompact"), (.grok, "unknown_event"),
        (.openCode, "PreCompact"), (.openCode, "PostCompact"), (.openCode, "UnknownEvent"),
        (.pi, "PreCompact"), (.pi, "PostCompact"), (.pi, "UnknownEvent"),
    ])
    func ignoredEventsAreSilent(provider: AgentHookProvider, hookEventName: String) {
        #expect(AgentHookEventMapper.event(provider: provider, hookEventName: hookEventName) == nil)
    }

    @Test
    func codexPermissionRequestMapsToPermissionPromptWithoutExecution() throws {
        let event = try #require(AgentHookEventMapper.event(
            provider: .codex,
            hookEventName: "PermissionRequest"
        ))

        #expect(event.executionState == nil)
        #expect(event.attentionReason == .permissionPrompt)
        #expect(event.phase == .notification)
    }

    @Test
    func openCodePermissionRepliedMapsToPermissionRepliedPhase() throws {
        let event = try #require(
            AgentHookEventMapper.event(
                provider: .openCode,
                hookEventName: "PermissionReplied"
            ))

        #expect(event.source == .openCode)
        #expect(event.kind == .openCode)
        #expect(event.executionState == nil)
        #expect(event.attentionReason == nil)
        #expect(event.phase == .permissionReplied)
    }

    @Test(arguments: [
        ("session_start", Optional(AgentExecutionState.idle), AttentionReason?.none, AgentRuntimePhase.sessionStart),
        ("user_prompt_submit", .thinking, nil, .promptSubmit),
        ("pre_tool_use", .thinking, nil, .toolStart),
        ("post_tool_use", .thinking, nil, .toolEnd),
        ("subagent_start", .thinking, nil, .toolStart),
        ("subagent_stop", .thinking, nil, .toolEnd),
        ("permission_denied", .error, nil, .notification),
        ("notification", nil, .userInputRequired, .notification),
        ("session_end", .idle, nil, .sessionEnd),
        ("stop_failure", .error, nil, .stop)
    ])
    func legacyGrokSnakeCaseEventsRemainAccepted(
        hookEventName: String,
        executionState: AgentExecutionState?,
        attentionReason: AttentionReason?,
        phase: AgentRuntimePhase
    ) throws {
        let event = try #require(AgentHookEventMapper.event(
            provider: .grok,
            hookEventName: hookEventName,
            providerSessionID: "grok-parent"
        ))

        #expect(event.executionState == executionState)
        #expect(event.attentionReason == attentionReason)
        #expect(event.phase == phase)
        #expect(event.providerSessionID == "grok-parent")
    }

    @Test(arguments: [
        ("end_turn", AgentExecutionState.waiting),
        ("shutdown", .error),
        (" cancel ", .error),
        ("error", .error),
        ("failed", .error),
        ("future_reason", .error)
    ])
    func grokStopReasonSplitsTurnEndFromErrors(
        reason: String,
        executionState: AgentExecutionState
    ) throws {
        let event = try #require(AgentHookEventMapper.event(
            provider: .grok,
            hookEventName: "stop",
            reason: reason
        ))

        #expect(event.executionState == executionState)
        #expect(event.attentionReason == nil)
        #expect(event.phase == .stop)
    }

    @Test("current Grok Stop without reason maps to waiting")
    func currentGrokStopWithoutReasonMapsToWaiting() throws {
        let event = try #require(AgentHookEventMapper.event(
            provider: .grok,
            hookEventName: "Stop"
        ))

        #expect(event.executionState == .waiting)
        #expect(event.attentionReason == nil)
        #expect(event.phase == .stop)
    }

    @Test("legacy Grok stop without reason keeps error behavior")
    func legacyGrokStopWithoutReasonKeepsErrorBehavior() throws {
        let event = try #require(AgentHookEventMapper.event(
            provider: .grok,
            hookEventName: "stop"
        ))

        #expect(event.executionState == .error)
        #expect(event.attentionReason == nil)
        #expect(event.phase == .stop)
    }

    @Test(arguments: [
        AgentHookProvider.openCode,
        .pi
    ])
    func localAgentNotificationsIgnoreNotificationType(provider: AgentHookProvider) throws {
        let event = try #require(AgentHookEventMapper.event(
            provider: provider,
            hookEventName: "Notification",
            notificationType: "permission_prompt"
        ))

        #expect(event.executionState == nil)
        #expect(event.attentionReason == .userInputRequired)
        #expect(event.phase == .notification)
    }

}
