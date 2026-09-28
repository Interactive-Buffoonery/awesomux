import AwesoMuxBridgeProtocol
import Foundation

public struct DaemonRecoveryMetadata: Hashable, Sendable {
    public static let labelPrefix = "awesomux."
    public static let maximumDecodedFieldBytes = 4 * 1024

    public let workspaceTitle: String?
    public let paneTitle: String?
    public let groupID: UUID?
    public let groupName: String?
    public let groupRemote: RemoteTarget?
    public let agentKind: AgentKind?

    public init(
        workspaceTitle: String?,
        paneTitle: String?,
        groupID: UUID?,
        groupName: String?,
        groupRemote: RemoteTarget?,
        agentKind: AgentKind?
    ) {
        self.workspaceTitle = Self.nonempty(workspaceTitle)
        self.paneTitle = Self.nonempty(paneTitle)
        self.groupID = groupID
        self.groupName = Self.nonempty(groupName)
        self.groupRemote = groupRemote
        self.agentKind = agentKind
    }

    public var encodedLabelAssignments: [String: String] {
        [
            Self.labelPrefix + "workspace-title": Self.encode(workspaceTitle),
            Self.labelPrefix + "pane-title": Self.encode(paneTitle),
            Self.labelPrefix + "group-id": Self.encode(groupID?.uuidString.lowercased()),
            Self.labelPrefix + "group-name": Self.encode(groupName),
            Self.labelPrefix + "group-remote": Self.encode(groupRemote),
            Self.labelPrefix + "agent-kind": Self.encode(agentKind?.rawValue),
        ]
    }

    public static func decode(fields: [String: String]) -> Self {
        let groupID = decodeString(fields[labelPrefix + "group-id"]).flatMap(UUID.init(uuidString:))
        let remote: RemoteTarget? = decodeData(fields[labelPrefix + "group-remote"]).flatMap {
            try? JSONDecoder().decode(RemoteTarget.self, from: $0)
        }
        let agent = decodeString(fields[labelPrefix + "agent-kind"]).flatMap(AgentKind.init(rawValue:))
        return Self(
            workspaceTitle: decodeString(fields[labelPrefix + "workspace-title"]),
            paneTitle: decodeString(fields[labelPrefix + "pane-title"]),
            groupID: groupID,
            groupName: decodeString(fields[labelPrefix + "group-name"]),
            groupRemote: remote,
            agentKind: agent
        )
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func encode(_ value: String?) -> String {
        guard let value else { return "" }
        return encode(Data(value.utf8))
    }

    private static func encode(_ value: RemoteTarget?) -> String {
        guard let value else { return "" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return "" }
        return encode(data)
    }

    private static func encode(_ data: Data) -> String {
        guard !data.isEmpty, data.count <= maximumDecodedFieldBytes else { return "" }
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decodeString(_ value: String?) -> String? {
        guard let data = decodeData(value) else { return nil }
        return String(data: data, encoding: .utf8).flatMap(nonempty)
    }

    private static func decodeData(_ value: String?) -> Data? {
        guard let value, !value.isEmpty,
            value.utf8.allSatisfy({
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                    || $0 == 45 || $0 == 95
            }), value.count % 4 != 1
        else { return nil }
        let standard = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padded = standard + String(repeating: "=", count: (4 - standard.count % 4) % 4)
        guard let data = Data(base64Encoded: padded), data.count <= maximumDecodedFieldBytes else {
            return nil
        }
        return data
    }
}
