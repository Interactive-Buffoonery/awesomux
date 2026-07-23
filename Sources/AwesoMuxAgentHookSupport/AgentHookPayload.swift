import Foundation

struct AgentHookPayload: Decodable {
    private var hookEventName: String?
    private var grokHookEventName: String?
    var notificationType: String?
    var providerSessionID: String?
    var reason: String?
    /// Native tool identity from a PostToolUse payload (`Write`/`Edit`/…). Used
    /// only to gate touched-path forwarding for file-mutating tools (issue #175);
    /// nothing else in the event carries tool payload.
    var toolName: String?
    /// `tool_input.file_path` from a PostToolUse payload — the file the tool
    /// addressed. Forwarded only when it survives the Markdown/scalar gate.
    var toolFilePath: String?

    enum CodingKeys: String, CodingKey {
        case hookEventName = "hook_event_name"
        case camelHookEventName = "hookEventName"
        case notificationType = "notification_type"
        case sessionID = "session_id"
        case legacySessionID = "sessionId"
        case reason
        case toolName = "tool_name"
        case toolInput = "tool_input"
    }

    private enum ToolInputKeys: String, CodingKey {
        case filePath = "file_path"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        hookEventName = try container.decodeIfPresent(String.self, forKey: .hookEventName)
        grokHookEventName = try container.decodeIfPresent(String.self, forKey: .camelHookEventName)
        notificationType = try container.decodeIfPresent(String.self, forKey: .notificationType)
        providerSessionID =
            try container.decodeIfPresent(String.self, forKey: .sessionID)
            ?? container.decodeIfPresent(String.self, forKey: .legacySessionID)
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
        toolName = try container.decodeIfPresent(String.self, forKey: .toolName)
        // Only pull `file_path` out of the (otherwise ignored) tool_input object;
        // content and every other tool arg stay unread so no prompt/tool payload
        // leaks through the side channel. A missing/mistyped tool_input (e.g. a
        // tool whose input is not an object) simply leaves the path nil.
        if let toolInput = try? container.nestedContainer(
            keyedBy: ToolInputKeys.self, forKey: .toolInput
        ) {
            toolFilePath = try? toolInput.decode(String.self, forKey: .filePath)
        } else {
            toolFilePath = nil
        }
    }

    func hookEventName(for provider: AgentHookProvider) -> String? {
        hookEventName ?? (provider == .grok ? grokHookEventName : nil)
    }
}
