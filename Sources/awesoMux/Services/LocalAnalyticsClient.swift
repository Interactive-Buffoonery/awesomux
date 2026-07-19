import AwesoMuxConfig
import Foundation
import Observation

/// Local-only analytics client: sanitizes and logs, sends nothing.
/// A later delivery slice replaces this with a PostHog-backed client behind
/// the same protocol; until then accepted events are logged with status
/// `dropped(delivery_unavailable)` — truthful, since no delivery
/// pipeline exists in this build.
@MainActor
@Observable
final class LocalAnalyticsClient: AnalyticsClient {
    let logStore: AnalyticsEventLogStore

    @ObservationIgnored private let consent: () -> AnalyticsConfig.ConsentLevel
    @ObservationIgnored private let sanitizer = AnalyticsSanitizer()
    @ObservationIgnored private let now: () -> Date

    init(
        logStore: AnalyticsEventLogStore,
        consent: @escaping () -> AnalyticsConfig.ConsentLevel,
        now: @escaping () -> Date = Date.init
    ) {
        self.logStore = logStore
        self.consent = consent
        self.now = now
    }

    func reconcileConsent(level: AnalyticsConfig.ConsentLevel) {
        if level != .off {
            _ = logStore.distinctID()
        }
    }

    func capture(_ input: AnalyticsEventInput) {
        let level = consent()
        // Opted out means no analytics bookkeeping at all — logging while
        // off would retain exactly the data the user declined to produce.
        guard level != .off else { return }

        switch sanitizer.sanitize(input, consent: level) {
        case .event(let event):
            append(
                event.name, properties: event.properties, level: level,
                status: .dropped, reason: .deliveryUnavailable)
        case .dropped(let reason):
            append(
                input.intendedName,
                properties: [:],
                level: level,
                status: .dropped,
                reason: reason
            )
        }
    }

    func optIn(level: AnalyticsConfig.ConsentLevel) {
        guard level != .off else { return }
        _ = logStore.distinctID()
        capture(.consentChanged(to: level))
    }

    @discardableResult
    func optOut(deleteLocalState: Bool) -> Bool {
        guard deleteLocalState else { return true }
        return logStore.deleteAll()
    }

    private func append(
        _ name: AnalyticsEventName,
        properties: [AnalyticsPropertyKey: AnalyticsPropertyValue],
        level: AnalyticsConfig.ConsentLevel,
        status: AnalyticsDeliveryStatus,
        reason: AnalyticsDropReason?
    ) {
        logStore.append(
            AnalyticsLogEntry(
                id: UUID(),
                timestamp: now(),
                name: name,
                consentLevel: level,
                properties: properties,
                status: status,
                dropReason: reason,
                provider: "posthog",
                schemaVersion: analyticsSchemaVersion
            )
        )
    }

}
