/// App-wide general behaviour settings introduced in schema v2.
public struct GeneralConfig: Codable, Equatable, Sendable {
    @TOMLDefault<DefaultRestoreWorkspaces> public var restoreWorkspaces: Bool
    @TOMLDefault<DefaultSidebarCompactMode> public var sidebarCompactMode: Bool
    @TOMLDefault<DefaultMenuBarVisibility> public var menuBarVisibility: MenuBarVisibility

    public static let defaultValue = GeneralConfig()

    public init(
        restoreWorkspaces: Bool = DefaultRestoreWorkspaces.defaultValue,
        sidebarCompactMode: Bool = DefaultSidebarCompactMode.defaultValue,
        menuBarVisibility: MenuBarVisibility = DefaultMenuBarVisibility.defaultValue
    ) {
        self.restoreWorkspaces = restoreWorkspaces
        self.sidebarCompactMode = sidebarCompactMode
        self.menuBarVisibility = menuBarVisibility
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case restoreWorkspaces = "restore_workspaces"
        case sidebarCompactMode = "sidebar_compact_mode"
        case menuBarVisibility = "menu_bar_visibility"
        case showMenuBarMiniStatus = "show_menu_bar_mini_status"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        _restoreWorkspaces = try container.decode(
            TOMLDefault<DefaultRestoreWorkspaces>.self,
            forKey: .restoreWorkspaces
        )
        _sidebarCompactMode = try container.decode(
            TOMLDefault<DefaultSidebarCompactMode>.self,
            forKey: .sidebarCompactMode
        )

        if container.contains(.menuBarVisibility) {
            _menuBarVisibility = try container.decode(
                TOMLDefault<DefaultMenuBarVisibility>.self,
                forKey: .menuBarVisibility
            )
        } else if let legacyValue = try container.decodeIfPresent(
            Bool.self,
            forKey: .showMenuBarMiniStatus
        ) {
            _menuBarVisibility = TOMLDefault(
                wrappedValue: legacyValue ? .needsInput : .never
            )
        } else {
            _menuBarVisibility = TOMLDefault(wrappedValue: DefaultMenuBarVisibility.defaultValue)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(restoreWorkspaces, forKey: .restoreWorkspaces)
        try container.encode(sidebarCompactMode, forKey: .sidebarCompactMode)
        try container.encode(menuBarVisibility, forKey: .menuBarVisibility)
    }
}

public struct DefaultRestoreWorkspaces: DefaultProvider {
    public static let defaultValue = true
}

public struct DefaultSidebarCompactMode: DefaultProvider {
    public static let defaultValue = false
}

public struct DefaultMenuBarVisibility: DefaultProvider {
    public static let defaultValue: GeneralConfig.MenuBarVisibility = .never
}

public extension GeneralConfig {
    enum MenuBarVisibility: String, Codable, CaseIterable, Equatable, Sendable {
        case never
        case needsInput = "needs_input"
        case always
    }
}
