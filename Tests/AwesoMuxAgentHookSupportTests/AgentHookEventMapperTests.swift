import AwesoMuxBridgeProtocol
import Testing
@testable import AwesoMuxAgentHookSupport
@testable import AwesoMuxCore

@Suite
struct AgentHookEventMapperTests {

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

}
