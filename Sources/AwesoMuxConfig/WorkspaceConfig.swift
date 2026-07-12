import Foundation
import UnicodeHygiene

public struct WorkspaceConfig: Codable, Equatable, Sendable {
    @TOMLDefault<DefaultWorkspaceDefaultGroup> private var defaultGroupStorage: String
    public var defaultGroup: String {
        get { defaultGroupStorage }
        set { defaultGroupStorage = Self.normalizedDefaultGroup(newValue) }
    }
    @TOMLDefault<DefaultOutputMarksNeedsAttention> public var outputMarksNeedsAttention: Bool
    @TOMLDefault<DefaultConfirmCloseWithRunningAgent> public var confirmCloseWithRunningAgent: Bool
    @TOMLDefault<DefaultConfirmDestructivePaneActionWithRunningAgent>
    public var confirmDestructivePaneActionWithRunningAgent: Bool
    /// Ordered bundle identifiers, top = highest priority. Empty means no
    /// explicit order yet; resolve time falls back to allowlist order. Unknown
    /// or uninstalled ids are tolerated and ignored when resolving.
    @TOMLDefault<DefaultDefaultIDEPriority> public var defaultIDEPriority: [String]
    /// When false, the titlebar "Open" control and the "Open in IDE" command
    /// are hidden entirely.
    @TOMLDefault<DefaultOpenInIDEEnabled> public var openInIDEEnabled: Bool

    public static let maxDefaultGroupLength = 80
    public static let canonicalDefaultGroupName = "awesoMux"

    public static let defaultValue = WorkspaceConfig(
        defaultGroup: canonicalDefaultGroupName,
        outputMarksNeedsAttention: true,
        confirmCloseWithRunningAgent: true,
        confirmDestructivePaneActionWithRunningAgent: true,
        defaultIDEPriority: [],
        openInIDEEnabled: true
    )

    public init(
        defaultGroup: String = WorkspaceConfig.canonicalDefaultGroupName,
        outputMarksNeedsAttention: Bool = true,
        confirmCloseWithRunningAgent: Bool = true,
        confirmDestructivePaneActionWithRunningAgent: Bool = true,
        defaultIDEPriority: [String] = [],
        openInIDEEnabled: Bool = true
    ) {
        self.defaultGroupStorage = Self.normalizedDefaultGroup(defaultGroup)
        self.outputMarksNeedsAttention = outputMarksNeedsAttention
        self.confirmCloseWithRunningAgent = confirmCloseWithRunningAgent
        self.confirmDestructivePaneActionWithRunningAgent = confirmDestructivePaneActionWithRunningAgent
        self.defaultIDEPriority = defaultIDEPriority
        self.openInIDEEnabled = openInIDEEnabled
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            defaultGroup: try container.decode(
                TOMLDefault<DefaultWorkspaceDefaultGroup>.self,
                forKey: .defaultGroup
            ).wrappedValue,
            outputMarksNeedsAttention: try container.decode(
                TOMLDefault<DefaultOutputMarksNeedsAttention>.self,
                forKey: .outputMarksNeedsAttention
            ).wrappedValue,
            confirmCloseWithRunningAgent: try container.decode(
                TOMLDefault<DefaultConfirmCloseWithRunningAgent>.self,
                forKey: .confirmCloseWithRunningAgent
            ).wrappedValue,
            confirmDestructivePaneActionWithRunningAgent: try container.decode(
                TOMLDefault<DefaultConfirmDestructivePaneActionWithRunningAgent>.self,
                forKey: .confirmDestructivePaneActionWithRunningAgent
            ).wrappedValue,
            defaultIDEPriority: try container.decode(
                TOMLDefault<DefaultDefaultIDEPriority>.self,
                forKey: .defaultIDEPriority
            ).wrappedValue,
            openInIDEEnabled: try container.decode(
                TOMLDefault<DefaultOpenInIDEEnabled>.self,
                forKey: .openInIDEEnabled
            ).wrappedValue
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(defaultGroup, forKey: .defaultGroup)
        try container.encode(outputMarksNeedsAttention, forKey: .outputMarksNeedsAttention)
        try container.encode(confirmCloseWithRunningAgent, forKey: .confirmCloseWithRunningAgent)
        try container.encode(
            confirmDestructivePaneActionWithRunningAgent,
            forKey: .confirmDestructivePaneActionWithRunningAgent
        )
        try container.encode(defaultIDEPriority, forKey: .defaultIDEPriority)
        try container.encode(openInIDEEnabled, forKey: .openInIDEEnabled)
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case defaultGroup = "default_group"
        case outputMarksNeedsAttention = "output_marks_needs_attention"
        case confirmCloseWithRunningAgent = "confirm_close_with_running_agent"
        case confirmDestructivePaneActionWithRunningAgent = "confirm_destructive_pane_action_with_running_agent"
        case defaultIDEPriority = "default_ide_priority"
        case openInIDEEnabled = "open_in_ide_enabled"
    }
}

public struct DefaultWorkspaceDefaultGroup: DefaultProvider {
    public static let defaultValue = WorkspaceConfig.canonicalDefaultGroupName
}

public struct DefaultOutputMarksNeedsAttention: DefaultProvider {
    public static let defaultValue = true
}

public struct DefaultConfirmCloseWithRunningAgent: DefaultProvider {
    public static let defaultValue = true
}

public struct DefaultConfirmDestructivePaneActionWithRunningAgent: DefaultProvider {
    public static let defaultValue = true
}

public struct DefaultDefaultIDEPriority: DefaultProvider {
    public static let defaultValue: [String] = []
}

public struct DefaultOpenInIDEEnabled: DefaultProvider {
    public static let defaultValue = true
}

public extension WorkspaceConfig {
    /// Normalize a config `default_group` for storage. Shares the group-name
    /// sanitization policy via `UnicodeHygiene` — including stripping the
    /// invisible routing-key hazards that titles keep — then, because config
    /// decode can't surface a UI error, falls back to the canonical default
    /// when nothing visible survives or the name trips the mixed-script
    /// confusable policy (mirroring the store-side routing diversion, so config
    /// and runtime behavior can't diverge).
    static func normalizedDefaultGroup(_ rawName: String) -> String {
        guard !UnicodeHygiene.hasSuspiciousScriptMixing(rawName) else {
            return canonicalDefaultGroupName
        }

        let sanitized = UnicodeHygiene.sanitize(
            rawName,
            maxLength: maxDefaultGroupLength,
            stripInvisibleRoutingScalars: true
        )
        return sanitized.isEmpty ? canonicalDefaultGroupName : sanitized
    }
}

extension WorkspaceConfig {
    func validate() throws(ConfigLoadError) {
        let normalized = Self.normalizedDefaultGroup(defaultGroup)
        guard defaultGroup == normalized else {
            throw .invalidValue(
                path: "workspaces.default_group",
                message: "Default group must be a non-empty sanitized group name"
            )
        }
    }
}
