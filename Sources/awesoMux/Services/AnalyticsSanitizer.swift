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
                let area = AnalyticsPropertyValue.token(validating: "analytics")
            else { return .dropped(.invalidPropertyValue) }
            properties = [.settingsArea: area, .consentLevel: value]

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

    /// Final semantic gate shared by persistence and transport. Per-key shape
    /// validation alone would allow required fields to be omitted or attached
    /// to the wrong event.
    static func isEventValid(_ event: SanitizedAnalyticsEvent) -> Bool {
        guard event.properties.allSatisfy({ isShapeValid($0.value, for: $0.key) }),
            event.properties[.schemaVersion] == .integer(analyticsSchemaVersion),
            case .token(let consentRaw) = event.properties[.consentLevel],
            let consent = AnalyticsConfig.ConsentLevel(rawValue: consentRaw),
            consent != .off
        else { return false }

        let common: Set<AnalyticsPropertyKey> = [.schemaVersion, .consentLevel]
        let required: Set<AnalyticsPropertyKey>
        let allowed: Set<AnalyticsPropertyKey>
        switch event.name {
        case .testPing:
            required = common
            allowed = common
        case .settingsChanged:
            required = common.union([.settingsArea])
            allowed = required
        case .appLaunched:
            required = common.union([
                .appVersion, .buildNumber, .macosVersionMajor, .macosVersionMinor, .cpuArch,
            ])
            allowed = required
        case .errorReported:
            required = common.union([.featureArea, .errorKind])
            allowed = required.union([.remoteContext, .activePaneRemote, .remotePaneCountBucket])
            let remoteKeys: Set<AnalyticsPropertyKey> = [
                .remoteContext, .activePaneRemote, .remotePaneCountBucket,
            ]
            let presentRemoteKeys = remoteKeys.intersection(event.properties.keys)
            if !presentRemoteKeys.isEmpty, presentRemoteKeys != remoteKeys { return false }
        case .diagnosticsOpened:
            required = common.union([.diagnosticsSection])
            allowed = required
        }

        let keys = Set(event.properties.keys)
        guard required.isSubset(of: keys), keys.isSubset(of: allowed) else { return false }
        if consent != .productUsage {
            switch event.name {
            case .testPing, .errorReported, .settingsChanged:
                break
            case .appLaunched, .diagnosticsOpened:
                return false
            }
        }
        return true
    }

    static func tier(for input: AnalyticsEventInput) -> AnalyticsConfig.ConsentLevel {
        switch input {
        case .testPing, .errorReported, .consentChanged:
            .errorReports
        case .appLaunched, .diagnosticsOpened:
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
        case .macosVersionMajor, .macosVersionMinor:
            if case .integer = value { return true }
            return false
        case .remotePaneCountBucket:
            if case .bucket = value { return true }
            return false
        case .activePaneRemote:
            switch value {
            case .bool: return true
            case .token(let token): return token == "unknown"
            default: return false
            }
        case .cpuArch:
            if case .token(let raw) = value {
                return AnalyticsPropertyValue.token(validating: raw) == value
            }
            return false
        case .featureArea:
            return token(value, belongsTo: AnalyticsFeatureArea.self)
        case .errorKind:
            return token(value, belongsTo: AnalyticsErrorKind.self)
        case .remoteContext:
            return token(value, belongsTo: AnalyticsRemoteContext.Presence.self)
        case .diagnosticsSection:
            return token(value, belongsTo: AnalyticsDiagnosticsSection.self)
        case .schemaVersion:
            return value == .integer(analyticsSchemaVersion)
        case .consentLevel:
            return token(value, belongsTo: AnalyticsConfig.ConsentLevel.self)
        case .settingsArea:
            return value == .token("analytics")
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
