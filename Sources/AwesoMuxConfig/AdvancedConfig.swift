public struct AdvancedConfig: Codable, Equatable, Sendable {
    @TOMLDefault<DefaultConfigSchemaVersion> public var configSchemaVersion: Int

    public static let minimumConfigSchemaVersion = 1
    public static let supportedConfigSchemaVersion = 2

    public static let defaultValue = AdvancedConfig(
        configSchemaVersion: supportedConfigSchemaVersion
    )

    public init(configSchemaVersion: Int = AdvancedConfig.supportedConfigSchemaVersion) {
        self.configSchemaVersion = configSchemaVersion
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case configSchemaVersion = "config_schema_version"
    }
}

public struct DefaultConfigSchemaVersion: DefaultProvider {
    /// An absent config_schema_version decodes as the CURRENT supported
    /// version. Any future load-time migration keyed on this value must
    /// revisit that assumption — an old file missing the key would be
    /// mistaken for an already-migrated one.
    public static let defaultValue = AdvancedConfig.supportedConfigSchemaVersion
}
