import Foundation

public enum WorkspaceGroupColor: String, CaseIterable, Codable, Hashable, Sendable {
    case mauve
    case peach
    case green
    case teal
    case blue
    case pink
    case yellow
    case red
    case gray
    case sky
    case lavender

    public static let pickerCases: [WorkspaceGroupColor] = [
        .mauve, .peach, .green, .teal, .blue, .pink, .yellow, .red, .gray,
    ]

    public var displayName: String {
        switch self {
        case .mauve: String(localized: "Mauve", comment: "Workspace group tint color")
        case .peach: String(localized: "Peach", comment: "Workspace group tint color")
        case .green: String(localized: "Green", comment: "Workspace group tint color")
        case .teal: String(localized: "Teal", comment: "Workspace group tint color")
        case .blue: String(localized: "Blue", comment: "Workspace group tint color")
        case .pink: String(localized: "Pink", comment: "Workspace group tint color")
        case .yellow: String(localized: "Yellow", comment: "Workspace group tint color")
        case .red: String(localized: "Red", comment: "Workspace group tint color")
        case .gray: String(localized: "Gray", comment: "Workspace group tint color")
        case .sky: String(localized: "Sky", comment: "Workspace group tint color")
        case .lavender: String(localized: "Lavender", comment: "Workspace group tint color")
        }
    }
}

public struct SessionGroup: Identifiable, Hashable, Sendable {
    public private(set) var id: UUID
    public var name: String
    public var color: WorkspaceGroupColor?
    /// Declared SSH destination when this is a remote workgroup; nil = local.
    /// Additive & omitted-when-nil so old snapshots decode unchanged — no
    /// `SessionSnapshot.currentSchemaVersion` bump (the `pinnedSessionIDs`
    /// precedent).
    public var remote: RemoteTarget?
    public var sessions: [TerminalSession]

    public init(
        id: UUID = UUID(),
        name: String,
        color: WorkspaceGroupColor? = nil,
        remote: RemoteTarget? = nil,
        sessions: [TerminalSession]
    ) {
        self.id = id
        self.name = name
        self.color = color
        self.remote = remote
        self.sessions = sessions
    }

    mutating func reassignIDForRestore(_ id: UUID) {
        self.id = id
    }
}

extension SessionGroup: Codable {
    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case color
        case remote
        case sessions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Colors are cosmetic, so unknown or malformed values can fall back
        // to no tint without changing the group's transport behavior.
        let rawColor = (try? container.decodeIfPresent(String.self, forKey: .color)) ?? nil
        let remote = try container.decodeIfPresent(RemoteTarget.self, forKey: .remote)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            color: rawColor.flatMap(WorkspaceGroupColor.init(rawValue:)),
            remote: remote,
            sessions: try container.decode([TerminalSession].self, forKey: .sessions)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(color?.rawValue, forKey: .color)
        try container.encodeIfPresent(remote, forKey: .remote)
        try container.encode(sessions, forKey: .sessions)
    }
}
