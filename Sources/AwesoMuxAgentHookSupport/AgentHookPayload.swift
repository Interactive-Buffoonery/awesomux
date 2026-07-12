import Foundation

struct AgentHookPayload: Decodable {
    private var hookEventName: String?
    private var grokHookEventName: String?
    var notificationType: String?
    var providerSessionID: String?
    var reason: String?

    enum CodingKeys: String, CodingKey {
        case hookEventName = "hook_event_name"
        case camelHookEventName = "hookEventName"
        case notificationType = "notification_type"
        case sessionID = "session_id"
        case legacySessionID = "sessionId"
        case reason
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        hookEventName = try container.decodeIfPresent(String.self, forKey: .hookEventName)
        grokHookEventName = try container.decodeIfPresent(String.self, forKey: .camelHookEventName)
        notificationType = try container.decodeIfPresent(String.self, forKey: .notificationType)
        providerSessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
            ?? container.decodeIfPresent(String.self, forKey: .legacySessionID)
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
    }

    func hookEventName(for provider: AgentHookProvider) -> String? {
        hookEventName ?? (provider == .grok ? grokHookEventName : nil)
    }
}
