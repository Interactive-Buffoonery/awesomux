public struct AgentIntegrationsConfig: Codable, Equatable, Sendable {
    @TOMLDefault<AgentIntegrationSetupDefaultProvider>
    public var claudeCode: AgentIntegrationSetup

    @TOMLDefault<AgentIntegrationSetupDefaultProvider>
    public var codex: AgentIntegrationSetup

    @TOMLDefault<AgentIntegrationSetupDefaultProvider>
    public var openCode: AgentIntegrationSetup

    @TOMLDefault<AgentIntegrationSetupDefaultProvider>
    public var pi: AgentIntegrationSetup

    @TOMLDefault<AgentIntegrationSetupDefaultProvider>
    public var grok: AgentIntegrationSetup

    public static let defaultValue = AgentIntegrationsConfig()

    public init(
        claudeCode: AgentIntegrationSetup = .defaultValue,
        codex: AgentIntegrationSetup = .defaultValue,
        openCode: AgentIntegrationSetup = .defaultValue,
        pi: AgentIntegrationSetup = .defaultValue,
        grok: AgentIntegrationSetup = .defaultValue
    ) {
        self.claudeCode = claudeCode
        self.codex = codex
        self.openCode = openCode
        self.pi = pi
        self.grok = grok
    }

    enum CodingKeys: String, CodingKey {
        case claudeCode = "claude_code"
        case codex
        case openCode = "open_code"
        case pi
        case grok
    }
}

public struct AgentIntegrationSetup: Codable, Equatable, Sendable {
    @TOMLDefault<AgentIntegrationEnabledDefaultProvider>
    public var enabled: Bool

    public var binaryPath: String?
    public var configHome: String?
    /// More config folders to manage alongside `configHome` (e.g. a second
    /// `CLAUDE_CONFIG_DIR`). Each folder keeps its own install.
    public var additionalConfigHomes: [String]?

    public static let defaultValue = AgentIntegrationSetup()

    public init(
        enabled: Bool = false,
        binaryPath: String? = nil,
        configHome: String? = nil,
        additionalConfigHomes: [String]? = nil
    ) {
        self.enabled = enabled
        self.binaryPath = binaryPath
        self.configHome = configHome
        self.additionalConfigHomes = additionalConfigHomes
    }

    enum CodingKeys: String, CodingKey {
        case enabled
        case binaryPath = "binary_path"
        case configHome = "config_home"
        case additionalConfigHomes = "additional_config_homes"
    }
}

public enum AgentIntegrationEnabledDefaultProvider: DefaultProvider {
    public static let defaultValue = false
}

public enum AgentIntegrationSetupDefaultProvider: DefaultProvider {
    public static let defaultValue = AgentIntegrationSetup.defaultValue
}
