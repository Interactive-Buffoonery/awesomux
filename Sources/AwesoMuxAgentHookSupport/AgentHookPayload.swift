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
        // `try?`, for the same reason as `tool_name` below and the wire and
        // bridge decoders: a present-but-wrong-type session id must strip only
        // itself, never throw out of the whole decode and drop the lifecycle
        // transition it rides on. This is the write end — the earliest of the
        // four boundaries that field crosses — so a throw here loses the event
        // before it is ever appended.
        // Two explicit steps rather than one coalescing chain. The chain form
        // behaves correctly but reads as though a wrong-typed `session_id`
        // would consume the lookup and starve the legacy spelling — a review
        // pass flagged it as broken, and it takes a test to prove otherwise.
        // `aWrongTypedSessionIDStillFallsThroughToTheLegacySpelling` pins it.
        let reportedSessionID =
            (try? container.decodeIfPresent(String.self, forKey: .sessionID)) ?? nil
        let legacyReportedSessionID =
            (try? container.decodeIfPresent(String.self, forKey: .legacySessionID)) ?? nil
        providerSessionID = reportedSessionID ?? legacyReportedSessionID
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
        // `try?`, not `try`: a present-but-wrong-type `tool_name` must not throw
        // out of the whole decode and drop the event's lifecycle transition —
        // it only gates touched-path forwarding. Same defensive posture as
        // `tool_input` below.
        toolName = (try? container.decodeIfPresent(String.self, forKey: .toolName)) ?? nil
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
