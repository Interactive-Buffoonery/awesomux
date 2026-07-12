import Foundation
import Testing
@testable import AwesoMuxAgentHookSupport
@testable import AwesoMuxCore

@Suite
struct AgentHookEventMapperTests {
    @Test(arguments: [
        ("SessionStart", AgentExecutionState.idle, AgentRuntimePhase.sessionStart),
        ("UserPromptSubmit", .thinking, .promptSubmit),
        ("PreToolUse", .thinking, .toolStart),
        ("PostToolUse", .thinking, .toolEnd),
        ("SubagentStart", .thinking, .toolStart),
        ("SubagentStop", .thinking, .toolEnd),
        ("SessionEnd", .idle, .sessionEnd),
        ("StopFailure", .error, .stop)
    ])
    func mappedClaudeCodeExecutionEvents(
        hookEventName: String,
        executionState: AgentExecutionState,
        phase: AgentRuntimePhase
    ) throws {
        let timestamp = Date(timeIntervalSince1970: 1_790_429_673.123)
        let event = try #require(AgentHookEventMapper.event(
            provider: .claudeCode,
            hookEventName: hookEventName,
            eventID: "event-id",
            timestamp: timestamp
        ))

        #expect(event.source == .claudeCode)
        #expect(event.kind == .claudeCode)
        #expect(event.executionState == executionState)
        #expect(event.attentionReason == nil)
        #expect(event.phase == phase)
        #expect(event.eventID == "event-id")
        #expect(event.timestamp == timestamp)
    }

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
        #expect(!displayState.triggersNotification)
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

    @Test(arguments: ["UnknownEvent"])
    func claudeCodeIgnoredEventsAreSilent(hookEventName: String) {
        #expect(AgentHookEventMapper.event(
            provider: .claudeCode,
            hookEventName: hookEventName
        ) == nil)
    }

    @Test(arguments: [
        ("SessionStart", Optional(AgentExecutionState.idle), nil, AgentRuntimePhase.sessionStart),
        ("UserPromptSubmit", .thinking, nil, .promptSubmit),
        ("PreToolUse", .thinking, nil, .toolStart),
        ("PostToolUse", .thinking, nil, .toolEnd),
        ("SubagentStart", .thinking, nil, .toolStart),
        ("SubagentStop", .thinking, nil, .toolEnd),
        ("PermissionRequest", nil, AttentionReason.permissionPrompt, .notification),
        ("Stop", .waiting, nil, .stop),
        ("Notification", nil, AttentionReason.userInputRequired, .notification),
        ("SessionEnd", .idle, nil, .sessionEnd),
        ("StopFailure", .error, nil, .stop)
    ])
    func mappedCodexEvents(
        hookEventName: String,
        executionState: AgentExecutionState?,
        attentionReason: AttentionReason?,
        phase: AgentRuntimePhase
    ) throws {
        let timestamp = Date(timeIntervalSince1970: 1_790_429_673.456)
        let event = try #require(AgentHookEventMapper.event(
            provider: .codex,
            hookEventName: hookEventName,
            eventID: "event-id",
            timestamp: timestamp
        ))

        #expect(event.source == .codex)
        #expect(event.kind == .codex)
        #expect(event.executionState == executionState)
        #expect(event.attentionReason == attentionReason)
        #expect(event.phase == phase)
        #expect(event.eventID == "event-id")
        #expect(event.timestamp == timestamp)
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

    @Test(arguments: [
        "PreCompact",
        "PostCompact",
        "UnknownEvent"
    ])
    func codexIgnoredEventsAreSilent(hookEventName: String) {
        #expect(AgentHookEventMapper.event(
            provider: .codex,
            hookEventName: hookEventName
        ) == nil)
    }

    @Test(arguments: [
        ("SessionStart", Optional(AgentExecutionState.idle), nil, AgentRuntimePhase.sessionStart),
        ("UserPromptSubmit", .thinking, nil, .promptSubmit),
        ("PreToolUse", .thinking, nil, .toolStart),
        ("PostToolUse", .thinking, nil, .toolEnd),
        ("SubagentStart", .thinking, nil, .toolStart),
        ("SubagentStop", .thinking, nil, .toolEnd),
        ("PermissionDenied", .error, nil, .notification),
        ("Notification", nil, AttentionReason.userInputRequired, .notification),
        ("Stop", .waiting, nil, .stop),
        ("SessionEnd", .idle, nil, .sessionEnd),
        ("StopFailure", .error, nil, .stop)
    ])
    func mappedCurrentGrokEvents(
        hookEventName: String,
        executionState: AgentExecutionState?,
        attentionReason: AttentionReason?,
        phase: AgentRuntimePhase
    ) throws {
        let timestamp = Date(timeIntervalSince1970: 1_790_429_674.123)
        let event = try #require(AgentHookEventMapper.event(
            provider: .grok,
            hookEventName: hookEventName,
            providerSessionID: "grok-parent",
            eventID: "event-id",
            timestamp: timestamp
        ))

        #expect(event.source == .grok)
        #expect(event.kind == .grok)
        #expect(event.executionState == executionState)
        #expect(event.attentionReason == attentionReason)
        #expect(event.phase == phase)
        #expect(event.providerSessionID == "grok-parent")
        #expect(event.eventID == "event-id")
        #expect(event.timestamp == timestamp)
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

    @Test("unknown Grok events are silent")
    func unknownGrokEventsAreSilent() {
        #expect(AgentHookEventMapper.event(
            provider: .grok,
            hookEventName: "PreCompact"
        ) == nil)
        #expect(AgentHookEventMapper.event(
            provider: .grok,
            hookEventName: "unknown_event"
        ) == nil)
    }

    @Test(
        arguments: [
            LocalAgentProviderCase(provider: .openCode, source: .openCode, kind: .openCode),
            LocalAgentProviderCase(provider: .pi, source: .pi, kind: .pi)
        ],
        [
            LocalAgentMappingCase(
                hookEventName: "SessionStart",
                executionState: .idle,
                attentionReason: nil,
                phase: .sessionStart
            ),
            LocalAgentMappingCase(
                hookEventName: "UserPromptSubmit",
                executionState: .thinking,
                attentionReason: nil,
                phase: .promptSubmit
            ),
            LocalAgentMappingCase(
                hookEventName: "PreToolUse",
                executionState: .thinking,
                attentionReason: nil,
                phase: .toolStart
            ),
            LocalAgentMappingCase(
                hookEventName: "PostToolUse",
                executionState: .thinking,
                attentionReason: nil,
                phase: .toolEnd
            ),
            LocalAgentMappingCase(
                hookEventName: "SubagentStart",
                executionState: .thinking,
                attentionReason: nil,
                phase: .toolStart
            ),
            LocalAgentMappingCase(
                hookEventName: "SubagentStop",
                executionState: .thinking,
                attentionReason: nil,
                phase: .toolEnd
            ),
            LocalAgentMappingCase(
                hookEventName: "PermissionRequest",
                executionState: nil,
                attentionReason: .permissionPrompt,
                phase: .notification
            ),
            LocalAgentMappingCase(
                hookEventName: "Notification",
                executionState: nil,
                attentionReason: .userInputRequired,
                phase: .notification
            ),
            LocalAgentMappingCase(
                hookEventName: "Stop",
                executionState: .waiting,
                attentionReason: nil,
                phase: .stop
            ),
            LocalAgentMappingCase(
                hookEventName: "SessionEnd",
                executionState: .idle,
                attentionReason: nil,
                phase: .sessionEnd
            ),
            LocalAgentMappingCase(
                hookEventName: "StopFailure",
                executionState: .error,
                attentionReason: nil,
                phase: .stop
            )
        ]
    )
    func mappedLocalAgentSyntheticEvents(
        providerCase: LocalAgentProviderCase,
        mappingCase: LocalAgentMappingCase
    ) throws {
        let timestamp = Date(timeIntervalSince1970: 1_790_429_673.789)
        let event = try #require(AgentHookEventMapper.event(
            provider: providerCase.provider,
            hookEventName: mappingCase.hookEventName,
            eventID: "event-id",
            timestamp: timestamp
        ))

        #expect(event.source == providerCase.source)
        #expect(event.kind == providerCase.kind)
        #expect(event.executionState == mappingCase.executionState)
        #expect(event.attentionReason == mappingCase.attentionReason)
        #expect(event.phase == mappingCase.phase)
        #expect(event.eventID == "event-id")
        #expect(event.timestamp == timestamp)
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

    @Test(
        arguments: [
            AgentHookProvider.openCode,
            .pi
        ],
        [
            "PreCompact",
            "PostCompact",
            "UnknownEvent"
        ]
    )
    func localAgentIgnoredEventsAreSilent(
        provider: AgentHookProvider,
        hookEventName: String
    ) {
        #expect(AgentHookEventMapper.event(
            provider: provider,
            hookEventName: hookEventName
        ) == nil)
    }

    struct LocalAgentProviderCase: Sendable {
        var provider: AgentHookProvider
        var source: AgentRuntimeSource
        var kind: AgentKind
    }

    struct LocalAgentMappingCase: Sendable {
        var hookEventName: String
        var executionState: AgentExecutionState?
        var attentionReason: AttentionReason?
        var phase: AgentRuntimePhase
    }
}
