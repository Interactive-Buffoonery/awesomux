import Foundation

struct AgentHookPayload: Decodable {
    private var hookEventName: String?
    private var grokHookEventName: String?
    var notificationType: String?
    var providerSessionID: String?
    var parentConversationID: String?
    /// Stable identity shared by hooks for the same tool invocation. This lets
    /// the reducer distinguish the prompted tool from concurrent work without
    /// forwarding tool input or output.
    var toolUseID: String?
    var reason: String?
    /// Native tool identity from a PostToolUse payload (`Write`/`Edit`/…). Used
    /// only to gate touched-path forwarding for file-mutating tools (issue #175);
    /// nothing else in the event carries tool payload.
    var toolName: String?
    /// `tool_input.file_path` from a PostToolUse payload — the file the tool
    /// addressed. Forwarded only when it survives the Markdown/scalar gate.
    var toolFilePath: String?
    var permissionSummary: String?

    enum CodingKeys: String, CodingKey {
        case hookEventName = "hook_event_name"
        case camelHookEventName = "hookEventName"
        case notificationType = "notification_type"
        case sessionID = "session_id"
        case legacySessionID = "sessionId"
        case conversationID = "conversationId"
        case snakeConversationID = "conversation_id"
        case parentConversationID = "parentConversationId"
        case snakeParentConversationID = "parent_conversation_id"
        case toolUseID = "tool_use_id"
        case legacyToolUseID = "toolUseId"
        case reason
        case terminationReason = "terminationReason"
        case snakeTerminationReason = "termination_reason"
        case toolName = "tool_name"
        case toolInput = "tool_input"
        case toolCall = "toolCall"
        case snakeToolCall = "tool_call"
    }

    private enum ToolCallKeys: String, CodingKey {
        case name
        case args
    }

    private enum ToolInputKeys: String, CodingKey {
        case filePath = "file_path"
        case capitalPath = "Path"
        case command
        case description
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        hookEventName = try container.decodeIfPresent(String.self, forKey: .hookEventName)
        grokHookEventName = try container.decodeIfPresent(String.self, forKey: .camelHookEventName)
        notificationType = try container.decodeIfPresent(String.self, forKey: .notificationType)
        // `try?`, for the same reason as `tool_name` below and the wire and
        // bridge decoders: a present-but-wrong-type session id must strip only
        // itself, never throw out of the whole decode and drop the lifecycle
        // transition it rides on. This is the write end — the earliest of the
        // four boundaries that field crosses — so a throw here loses the event
        // before it is ever appended.
        let reportedSessionID =
            (try? container.decodeIfPresent(String.self, forKey: .sessionID)) ?? nil
        let legacyReportedSessionID =
            (try? container.decodeIfPresent(String.self, forKey: .legacySessionID)) ?? nil
        let reportedConversationID =
            (try? container.decodeIfPresent(String.self, forKey: .conversationID)) ?? nil
        let snakeReportedConversationID =
            (try? container.decodeIfPresent(String.self, forKey: .snakeConversationID)) ?? nil
        providerSessionID =
            reportedSessionID
            ?? legacyReportedSessionID
            ?? reportedConversationID
            ?? snakeReportedConversationID
        let reportedParentConversationID =
            (try? container.decodeIfPresent(String.self, forKey: .parentConversationID)) ?? nil
        let snakeReportedParentConversationID =
            (try? container.decodeIfPresent(String.self, forKey: .snakeParentConversationID)) ?? nil
        parentConversationID = reportedParentConversationID ?? snakeReportedParentConversationID
        let reportedToolUseID =
            (try? container.decodeIfPresent(String.self, forKey: .toolUseID)) ?? nil
        let legacyReportedToolUseID =
            (try? container.decodeIfPresent(String.self, forKey: .legacyToolUseID)) ?? nil
        toolUseID = reportedToolUseID ?? legacyReportedToolUseID
        let explicitReason = (try? container.decodeIfPresent(String.self, forKey: .reason)) ?? nil
        let camelTerminationReason =
            (try? container.decodeIfPresent(String.self, forKey: .terminationReason)) ?? nil
        let snakeTerminationReason =
            (try? container.decodeIfPresent(String.self, forKey: .snakeTerminationReason)) ?? nil
        reason = explicitReason ?? camelTerminationReason ?? snakeTerminationReason
        // `try?`, not `try`: a present-but-wrong-type `tool_name` must not throw
        // out of the whole decode and drop the event's lifecycle transition —
        // it only gates touched-path forwarding. Same defensive posture as
        // `tool_input` below.
        let topLevelToolName =
            (try? container.decodeIfPresent(String.self, forKey: .toolName)) ?? nil
        let toolCallContainer =
            (try? container.nestedContainer(keyedBy: ToolCallKeys.self, forKey: .toolCall))
            ?? (try? container.nestedContainer(keyedBy: ToolCallKeys.self, forKey: .snakeToolCall))
        let nestedToolName = toolCallContainer.flatMap {
            try? $0.decodeIfPresent(String.self, forKey: .name)
        }
        toolName = topLevelToolName ?? nestedToolName
        // Only pull `file_path` out of the (otherwise ignored) tool_input object;
        // content and every other tool arg stay unread so no prompt/tool payload
        // leaks through the side channel. A missing/mistyped tool_input (e.g. a
        // tool whose input is not an object) simply leaves the path nil.
        if let toolInput = try? container.nestedContainer(
            keyedBy: ToolInputKeys.self, forKey: .toolInput
        ) {
            toolFilePath =
                (try? toolInput.decode(String.self, forKey: .filePath))
                ?? (try? toolInput.decode(String.self, forKey: .capitalPath))
            // Select bounded review text only; never forward the argument object,
            // tool response, file contents or environment. No summary is logged.
            permissionSummary =
                (try? toolInput.decode(String.self, forKey: .command))
                ?? toolFilePath
                ?? (try? toolInput.decode(String.self, forKey: .description))
        } else if let toolArgs = toolCallContainer.flatMap({
            try? $0.nestedContainer(keyedBy: ToolInputKeys.self, forKey: .args)
        }) {
            toolFilePath =
                (try? toolArgs.decode(String.self, forKey: .filePath))
                ?? (try? toolArgs.decode(String.self, forKey: .capitalPath))
        } else {
            toolFilePath = nil
        }
    }

    func hookEventName(for provider: AgentHookProvider) -> String? {
        hookEventName ?? (provider == .grok ? grokHookEventName : nil)
    }
}
