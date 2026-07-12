public struct AwesoMuxConfig: Codable, Equatable, Sendable {
    public var general: GeneralConfig
    public var appearance: AppearanceConfig
    public var notifications: NotificationConfig
    public var agents: AgentConfig
    public var agentIntegrations: AgentIntegrationsConfig
    public var keyboard: KeyboardConfig
    public var terminal: TerminalConfig
    public var workspaces: WorkspaceConfig
    public var advanced: AdvancedConfig

    /// Raw text of unknown top-level `[table]` blocks the user has
    /// hand-written into config.toml (e.g. an `[experimental]` block from
    /// a Fediverse blog post). The decoder captures these as raw TOML
    /// fragments and re-emits them on save so tinkerers don't lose their
    /// work the next time awesoMux rewrites the file. Keyed by table
    /// header name. NOT round-tripped through Codable — the table is
    /// reconstructed by TOMLConfigCodec from the source text at decode
    /// time.
    ///
    /// This is a top-level table contract. Intra-section unknown keys are
    /// preserved separately for owned sections that opt into raw line
    /// preservation, such as `[terminal]` and `[appearance]`.
    public var unknownTopLevelTables: [String: String] = [:]

    /// Raw unknown lines from `[terminal]`, preserved while awesoMux owns only
    /// a small subset of that table. Known terminal keys are emitted from
    /// `TerminalConfig`; only the rest of the table body passes through.
    public var unknownTerminalTableLines: String = ""
    var terminalTableLineLayout: [SectionLineLayout] = []

    /// Raw unknown lines from `[appearance]`, preserved while awesoMux owns only
    /// a small subset of that table. Known appearance keys are emitted from
    /// `AppearanceConfig`; only the rest of the table body passes through.
    public var unknownAppearanceTableLines: String = ""
    var appearanceTableLineLayout: [SectionLineLayout] = []

    public static let defaultValue = AwesoMuxConfig(
        general: .defaultValue,
        appearance: .defaultValue,
        notifications: .defaultValue,
        agents: .defaultValue,
        agentIntegrations: .defaultValue,
        keyboard: .defaultValue,
        terminal: .defaultValue,
        workspaces: .defaultValue,
        advanced: .defaultValue
    )

    public init(
        general: GeneralConfig = AwesoMuxConfig.defaultValue.general,
        appearance: AppearanceConfig = AwesoMuxConfig.defaultValue.appearance,
        notifications: NotificationConfig = AwesoMuxConfig.defaultValue.notifications,
        agents: AgentConfig = AwesoMuxConfig.defaultValue.agents,
        agentIntegrations: AgentIntegrationsConfig = AwesoMuxConfig.defaultValue.agentIntegrations,
        keyboard: KeyboardConfig = AwesoMuxConfig.defaultValue.keyboard,
        terminal: TerminalConfig = AwesoMuxConfig.defaultValue.terminal,
        workspaces: WorkspaceConfig = AwesoMuxConfig.defaultValue.workspaces,
        advanced: AdvancedConfig = AwesoMuxConfig.defaultValue.advanced,
        unknownTopLevelTables: [String: String] = [:],
        unknownTerminalTableLines: String = "",
        unknownAppearanceTableLines: String = ""
    ) {
        self.general = general
        self.appearance = appearance
        self.notifications = notifications
        self.agents = agents
        self.agentIntegrations = agentIntegrations
        self.keyboard = keyboard
        self.terminal = terminal
        self.workspaces = workspaces
        self.advanced = advanced
        self.unknownTopLevelTables = unknownTopLevelTables
        self.unknownTerminalTableLines = unknownTerminalTableLines
        self.unknownAppearanceTableLines = unknownAppearanceTableLines
    }

    /// Custom decoder so hand-edited TOML files can omit any top-level
    /// section and pick up that section's defaults. AdvancedSettingsPane
    /// invites users to edit the file directly — they should be able to
    /// delete sections they don't care about without breaking the decode.
    /// Field-level tolerance inside most sections comes from `@TOMLDefault`;
    /// this root decoder still owns whole-section defaulting.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let general = try container.decodeIfPresent(GeneralConfig.self, forKey: .general)
            ?? AwesoMuxConfig.defaultValue.general
        let appearance = try container.decodeIfPresent(AppearanceConfig.self, forKey: .appearance)
            ?? AwesoMuxConfig.defaultValue.appearance
        let notifications = try container.decodeIfPresent(NotificationConfig.self, forKey: .notifications)
            ?? AwesoMuxConfig.defaultValue.notifications
        let agents = try container.decodeIfPresent(AgentConfig.self, forKey: .agents)
            ?? AwesoMuxConfig.defaultValue.agents
        let agentIntegrations = try container.decodeIfPresent(
            AgentIntegrationsConfig.self,
            forKey: .agentIntegrations
        ) ?? AwesoMuxConfig.defaultValue.agentIntegrations
        let keyboard = try container.decodeIfPresent(KeyboardConfig.self, forKey: .keyboard)
            ?? AwesoMuxConfig.defaultValue.keyboard
        let terminal = try container.decodeIfPresent(TerminalConfig.self, forKey: .terminal)
            ?? AwesoMuxConfig.defaultValue.terminal
        let workspaces = try container.decodeIfPresent(WorkspaceConfig.self, forKey: .workspaces)
            ?? AwesoMuxConfig.defaultValue.workspaces
        let advanced = try container.decodeIfPresent(AdvancedConfig.self, forKey: .advanced)
            ?? AwesoMuxConfig.defaultValue.advanced

        self.init(
            general: general,
            appearance: appearance,
            notifications: notifications,
            agents: agents,
            agentIntegrations: agentIntegrations,
            keyboard: keyboard,
            terminal: terminal,
            workspaces: workspaces,
            advanced: advanced
        )
    }

    /// CodingKeys intentionally exclude `unknownTopLevelTables` — the
    /// catch-all is reconstructed by TOMLConfigCodec from the raw source
    /// at decode time and spliced back at encode time, not round-tripped
    /// through Codable.
    enum CodingKeys: String, CodingKey {
        case general
        case appearance
        case notifications
        case agents
        case agentIntegrations = "agent_integrations"
        case keyboard
        case terminal
        case workspaces
        case advanced
    }

    /// Set of top-level table names the structured decoder recognizes;
    /// anything else surfacing in the raw TOML is captured into
    /// `unknownTopLevelTables`.
    static let knownTopLevelTableNames: Set<String> = [
        "general",
        "appearance",
        "notifications",
        "agents",
        "agent_integrations",
        "keyboard",
        "terminal",
        "workspaces",
        "advanced"
    ]
}

enum SectionLineLayout: Equatable, Sendable {
    case knownKey(String)
    case unknownLine(Int)
}
