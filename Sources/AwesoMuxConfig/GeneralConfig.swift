/// App-wide general behaviour settings introduced in schema v2.
public struct GeneralConfig: Codable, Equatable, Sendable {
    @TOMLDefault<DefaultRestoreWorkspaces> public var restoreWorkspaces: Bool
    @TOMLDefault<DefaultSidebarCompactMode> public var sidebarCompactMode: Bool
    @TOMLDefault<DefaultShowMenuBarMiniStatus> public var showMenuBarMiniStatus: Bool

    public static let defaultValue = GeneralConfig()

    public init(
        restoreWorkspaces: Bool = DefaultRestoreWorkspaces.defaultValue,
        sidebarCompactMode: Bool = DefaultSidebarCompactMode.defaultValue,
        showMenuBarMiniStatus: Bool = DefaultShowMenuBarMiniStatus.defaultValue
    ) {
        self.restoreWorkspaces = restoreWorkspaces
        self.sidebarCompactMode = sidebarCompactMode
        self.showMenuBarMiniStatus = showMenuBarMiniStatus
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case restoreWorkspaces = "restore_workspaces"
        case sidebarCompactMode = "sidebar_compact_mode"
        case showMenuBarMiniStatus = "show_menu_bar_mini_status"
    }
}

public struct DefaultRestoreWorkspaces: DefaultProvider {
    public static let defaultValue = true
}

public struct DefaultSidebarCompactMode: DefaultProvider {
    public static let defaultValue = false
}

public struct DefaultShowMenuBarMiniStatus: DefaultProvider {
    public static let defaultValue = false
}
