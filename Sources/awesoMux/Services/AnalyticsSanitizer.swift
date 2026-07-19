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
        switch event.name {
        case .testPing:
            required = common
        case .settingsChanged:
            required = common.union([.settingsArea])
        }
        return Set(event.properties.keys) == required
    }

    static func isShapeValid(
        _ value: AnalyticsPropertyValue,
        for key: AnalyticsPropertyKey
    ) -> Bool {
        switch key {
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
