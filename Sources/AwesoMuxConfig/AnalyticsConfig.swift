import Foundation

/// `[analytics]` section of config.toml (ADR-0008). Consent is off by
/// default: analytics never leaves the machine unless the user opts in.
public struct AnalyticsConfig: Codable, Equatable, Sendable {
    @TOMLDefault<DefaultAnalyticsConsentLevel> public var consentLevel: ConsentLevel
    @TOMLDefault<DefaultRetainLocalEventLog> public var retainLocalEventLog: Bool
    @TOMLDefault<DefaultPostHogHost> public var posthogHost: String

    public static let defaultValue = AnalyticsConfig()

    public init(
        consentLevel: ConsentLevel = DefaultAnalyticsConsentLevel.defaultValue,
        retainLocalEventLog: Bool = DefaultRetainLocalEventLog.defaultValue,
        posthogHost: String = DefaultPostHogHost.defaultValue
    ) {
        self.consentLevel = consentLevel
        self.retainLocalEventLog = retainLocalEventLog
        self.posthogHost = posthogHost
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case consentLevel = "consent_level"
        case retainLocalEventLog = "retain_local_event_log"
        case posthogHost = "posthog_host"
    }

    public enum ConsentLevel: String, Codable, CaseIterable, Equatable, Sendable {
        case off
        case errorReports = "error_reports"
        case productUsage = "product_usage"
    }
}

extension AnalyticsConfig {
    func validate() throws(ConfigLoadError) {
        guard let host = URL(string: posthogHost), host.scheme?.lowercased() == "https", host.host() != nil else {
            throw .invalidValue(
                path: "analytics.posthog_host",
                message: "PostHog host must be an https URL"
            )
        }
    }
}

public struct DefaultAnalyticsConsentLevel: DefaultProvider {
    public static let defaultValue = AnalyticsConfig.ConsentLevel.off
}

public struct DefaultRetainLocalEventLog: DefaultProvider {
    public static let defaultValue = true
}

public struct DefaultPostHogHost: DefaultProvider {
    public static let defaultValue = "https://us.i.posthog.com"
}
