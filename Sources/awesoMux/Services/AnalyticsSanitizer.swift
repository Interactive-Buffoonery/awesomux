import AwesoMuxConfig
import Foundation

enum AnalyticsSanitizerResult: Equatable, Sendable {
    case event(SanitizedAnalyticsEvent)
    case dropped(AnalyticsDropReason)
}

/// Maps the closed `AnalyticsEventInput` enum to allowlisted payloads.
/// The switch in `sanitize` IS the event allowlist: an event that is not
/// mapped here cannot be logged or sent. Every payload additionally
/// passes a per-key shape check as defense in depth against a future
/// mapping bug.
struct AnalyticsSanitizer {
    func sanitize(
        _ input: AnalyticsEventInput,
        consent: AnalyticsConfig.ConsentLevel
    ) -> AnalyticsSanitizerResult {
        guard consent != .off else { return .dropped(.analyticsDisabled) }
        guard Self.rank(Self.tier(for: input)) <= Self.rank(consent) else {
            return .dropped(.consentInsufficient)
        }

        let name: AnalyticsEventName
        var properties: [AnalyticsPropertyKey: AnalyticsPropertyValue]
        switch input {
        case .testPing:
            name = .testPing
            properties = [:]

        case .consentChanged(let level):
            name = .settingsChanged
            guard let value = AnalyticsPropertyValue.token(validating: level.rawValue),
                let area = AnalyticsPropertyValue.token(validating: AnalyticsSettingsArea.analytics.rawValue)
            else { return .dropped(.invalidPropertyValue) }
            properties = [.settingsArea: area, .consentLevel: value]

        case .settingsChanged(let area):
            name = .settingsChanged
            guard let value = AnalyticsPropertyValue.token(validating: area.rawValue) else {
                return .dropped(.invalidPropertyValue)
            }
            properties = [.settingsArea: value]

        case .appLaunched(let snapshot):
            name = .appLaunched
            guard let appVersion = AnalyticsPropertyValue.version(validating: snapshot.appVersion),
                let build = AnalyticsPropertyValue.version(validating: snapshot.buildNumber),
                let arch = AnalyticsPropertyValue.token(validating: snapshot.cpuArchitecture)
            else { return .dropped(.invalidPropertyValue) }
            properties = [
                .appVersion: appVersion,
                .buildNumber: build,
                .macosVersionMajor: .integer(snapshot.macOSMajor),
                .macosVersionMinor: .integer(snapshot.macOSMinor),
                .cpuArch: arch,
            ]

        case .errorReported(let context):
            name = .errorReported
            guard let area = AnalyticsPropertyValue.token(validating: context.featureArea.rawValue),
                let kind = AnalyticsPropertyValue.token(validating: context.errorKind.rawValue)
            else { return .dropped(.invalidPropertyValue) }
            properties = [.featureArea: area, .errorKind: kind]
            if let remote = context.remote {
                guard let presence = AnalyticsPropertyValue.token(validating: remote.presence.rawValue) else {
                    return .dropped(.invalidPropertyValue)
                }
                properties[.remoteContext] = presence
                properties[.activePaneRemote] =
                    remote.activePaneRemote.map(AnalyticsPropertyValue.bool)
                    ?? .token("unknown")
                properties[.remotePaneCountBucket] = .bucket(CountBucket(count: remote.remotePaneCount))
            }

        case .sessionCreated(let shape, let sessionKind, let agentKind):
            name = .sessionCreated
            properties = Self.shapeProperties(shape)
            guard let kindToken = AnalyticsPropertyValue.token(validating: sessionKind.rawValue) else {
                return .dropped(.invalidPropertyValue)
            }
            properties[.sessionKind] = kindToken
            if let agentKind {
                guard let kind = AnalyticsPropertyValue.token(validating: agentKind.rawValue) else {
                    return .dropped(.invalidPropertyValue)
                }
                properties[.agentKind] = kind
            }

        case .agentSessionStarted(let kind, let initialState, let usesReliableHooks):
            name = .agentSessionStarted
            guard let kindValue = AnalyticsPropertyValue.token(validating: kind.rawValue),
                let state = AnalyticsPropertyValue.token(validating: initialState.rawValue)
            else { return .dropped(.invalidPropertyValue) }
            properties = [
                .agentKind: kindValue,
                .agentState: state,
                .usesReliableHooks: .bool(usesReliableHooks),
            ]

        case .agentStateChanged(let kind, let previous, let next, let source):
            name = .agentStateChanged
            guard let kindValue = AnalyticsPropertyValue.token(validating: kind.rawValue),
                let previousValue = AnalyticsPropertyValue.token(validating: previous.rawValue),
                let nextValue = AnalyticsPropertyValue.token(validating: next.rawValue),
                let sourceValue = AnalyticsPropertyValue.token(validating: source.rawValue)
            else { return .dropped(.invalidPropertyValue) }
            properties = [
                .agentKind: kindValue,
                .previousAgentState: previousValue,
                .nextAgentState: nextValue,
                .agentEventSource: sourceValue,
            ]

        case .workspaceGroupChanged(let action, let shape):
            name = .workspaceGroupChanged
            guard let actionValue = AnalyticsPropertyValue.token(validating: action.rawValue) else {
                return .dropped(.invalidPropertyValue)
            }
            properties = Self.shapeProperties(shape)
            properties[.action] = actionValue

        case .diagnosticsOpened(let section):
            name = .diagnosticsOpened
            guard let sectionValue = AnalyticsPropertyValue.token(validating: section.rawValue) else {
                return .dropped(.invalidPropertyValue)
            }
            properties = [.diagnosticsSection: sectionValue]
        }

        properties[.schemaVersion] = .integer(analyticsSchemaVersion)
        if properties[.consentLevel] == nil,
            let level = AnalyticsPropertyValue.token(validating: consent.rawValue)
        {
            properties[.consentLevel] = level
        }

        for (key, value) in properties where !Self.isShapeValid(value, for: key) {
            return .dropped(.invalidPropertyValue)
        }
        return .event(SanitizedAnalyticsEvent(name: name, properties: properties))
    }

    /// INT-768 consent tiers: only sanitized error events ride
    /// `error_reports`; everything product-shaped needs `product_usage`.
    /// The test ping is a user-initiated diagnostic aid, allowed at any
    /// enabled level. `consentChanged` also rides `error_reports`: it
    /// records the consent change itself, which is analytics-system
    /// metadata sanctioned at any enabled level, and INT-768 names the
    /// analytics consent level as the single allowed raw value on
    /// `amx_settings_changed` — otherwise an error_reports-only opt-in
    /// never reaches the provider.
    static func tier(for input: AnalyticsEventInput) -> AnalyticsConfig.ConsentLevel {
        switch input {
        case .testPing, .errorReported, .consentChanged:
            .errorReports
        case .settingsChanged, .appLaunched, .sessionCreated,
            .agentSessionStarted, .agentStateChanged, .workspaceGroupChanged,
            .diagnosticsOpened:
            .productUsage
        }
    }

    private static func rank(_ level: AnalyticsConfig.ConsentLevel) -> Int {
        switch level {
        case .off: 0
        case .errorReports: 1
        case .productUsage: 2
        }
    }

    private static func shapeProperties(
        _ shape: WorkspaceShapeSnapshot
    ) -> [AnalyticsPropertyKey: AnalyticsPropertyValue] {
        [
            .sessionCountBucket: .bucket(CountBucket(count: shape.sessionCount)),
            .paneCountBucket: .bucket(CountBucket(count: shape.paneCount)),
            .workspaceGroupCountBucket: .bucket(CountBucket(count: shape.groupCount)),
        ]
    }

    static func isShapeValid(
        _ value: AnalyticsPropertyValue,
        for key: AnalyticsPropertyKey
    ) -> Bool {
        switch key {
        case .appVersion, .buildNumber:
            if case .version(let raw) = value {
                return AnalyticsPropertyValue.version(validating: raw) == value
            }
            return false
        case .macosVersionMajor, .macosVersionMinor, .schemaVersion:
            // .integer carries no bounds check and is reserved for trusted
            // small-domain values (OS version, schema constant). Anything
            // user-influenced must ship as .bucket to cap cardinality.
            if case .integer = value { return true }
            return false
        case .sessionCountBucket, .paneCountBucket, .workspaceGroupCountBucket,
            .remotePaneCountBucket:
            if case .bucket = value { return true }
            return false
        case .activePaneRemote, .usesReliableHooks:
            switch value {
            case .bool: return true
            // INT-768 allows "unknown" for indeterminate remote detection.
            case .token(let token): return token == "unknown"
            default: return false
            }
        case .cpuArch:
            // CPU architecture strings are an open set and remain syntax-only tokens.
            if case .token(let raw) = value {
                return AnalyticsPropertyValue.token(validating: raw) == value
            }
            return false
        case .featureArea:
            return token(value, belongsTo: AnalyticsFeatureArea.self)
        case .errorKind:
            return token(value, belongsTo: AnalyticsErrorKind.self)
        case .consentLevel:
            return token(value, belongsTo: AnalyticsConfig.ConsentLevel.self)
        case .sessionKind:
            return token(value, belongsTo: AnalyticsSessionKind.self)
        case .remoteContext:
            return token(value, belongsTo: AnalyticsRemoteContext.Presence.self)
        case .agentKind:
            return token(value, belongsTo: AnalyticsAgentKind.self)
        case .agentState, .previousAgentState, .nextAgentState:
            return token(value, belongsTo: AnalyticsAgentState.self)
        case .agentEventSource:
            return token(value, belongsTo: AnalyticsAgentEventSource.self)
        case .settingsArea:
            return token(value, belongsTo: AnalyticsSettingsArea.self)
        case .diagnosticsSection:
            return token(value, belongsTo: AnalyticsDiagnosticsSection.self)
        case .action:
            return token(value, belongsTo: WorkspaceGroupAction.self)
        }
    }

    private static func token<Value>(
        _ value: AnalyticsPropertyValue,
        belongsTo type: Value.Type
    ) -> Bool where Value: CaseIterable & RawRepresentable, Value.RawValue == String {
        guard case .token(let raw) = value else { return false }
        return Value.allCases.contains { $0.rawValue == raw }
    }
}
