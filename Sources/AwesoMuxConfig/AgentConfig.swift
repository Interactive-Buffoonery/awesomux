public struct AgentConfig: Codable, Equatable, Sendable {
    @TOMLDefault<DefaultPermissionPosture> public var permissionPosture: PermissionPosture
    @TOMLDefault<DefaultRememberToolTrust> public var rememberToolTrust: Bool

    public static let defaultValue = AgentConfig()

    public init(
        permissionPosture: PermissionPosture = DefaultPermissionPosture.defaultValue,
        rememberToolTrust: Bool = DefaultRememberToolTrust.defaultValue
    ) {
        self.permissionPosture = permissionPosture
        self.rememberToolTrust = rememberToolTrust
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case permissionPosture = "permission_posture"
        case rememberToolTrust = "remember_tool_trust"
    }
}

public struct DefaultPermissionPosture: DefaultProvider {
    public static let defaultValue: AgentConfig.PermissionPosture = .askEveryTime
}

public struct DefaultRememberToolTrust: DefaultProvider {
    public static let defaultValue = true
}

public extension AgentConfig {
    enum PermissionPosture: String, Codable, CaseIterable, Equatable, Sendable {
        case askEveryTime = "ask_every_time"
        case rememberPerWorkspace = "remember_per_workspace"
        case trustKnownTools = "trust_known_tools"
    }
}
