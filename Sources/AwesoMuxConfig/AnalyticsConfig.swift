import Foundation

/// `[analytics]` section of config.toml (ADR-0008). Consent is off by
/// default: analytics never leaves the machine unless the user opts in.
public struct AnalyticsConfig: Codable, Equatable, Sendable {
    @TOMLDefault<DefaultAnalyticsConsentLevel> public var consentLevel: ConsentLevel
    @TOMLDefault<DefaultRetainLocalEventLog> public var retainLocalEventLog: Bool

    public static let defaultValue = AnalyticsConfig()

    public init(
        consentLevel: ConsentLevel = DefaultAnalyticsConsentLevel.defaultValue,
        retainLocalEventLog: Bool = DefaultRetainLocalEventLog.defaultValue
    ) {
        self.consentLevel = consentLevel
        self.retainLocalEventLog = retainLocalEventLog
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case consentLevel = "consent_level"
        case retainLocalEventLog = "retain_local_event_log"
    }

    public enum ConsentLevel: String, Codable, CaseIterable, Equatable, Sendable {
        case off
        case errorReports = "error_reports"
        case productUsage = "product_usage"
    }
}

extension AnalyticsConfig {
    func validate() throws(ConfigLoadError) {}
}

public struct DefaultAnalyticsConsentLevel: DefaultProvider {
    public static let defaultValue = AnalyticsConfig.ConsentLevel.off
}

public struct DefaultRetainLocalEventLog: DefaultProvider {
    public static let defaultValue = true
}
