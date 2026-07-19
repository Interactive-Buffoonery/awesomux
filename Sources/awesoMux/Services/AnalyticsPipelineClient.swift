import AwesoMuxConfig
import Foundation
import Observation

/// App-owned analytics policy pipeline. Consent, sanitization, local
/// transparency, and provider lifecycle live here so delivery cannot bypass
/// the app's privacy boundary.
@MainActor
@Observable
final class AnalyticsPipelineClient: AnalyticsClient {
    let logStore: AnalyticsEventLogStore

    @ObservationIgnored private let consent: () -> AnalyticsConfig.ConsentLevel
    @ObservationIgnored private let provider: any AnalyticsDeliveryProvider
    @ObservationIgnored private let sanitizer = AnalyticsSanitizer()
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var appliedLevel: AnalyticsConfig.ConsentLevel = .off
    @ObservationIgnored private var hasReconciledConsent = false
    @ObservationIgnored private var cachedAnonymousID: UUID?

    init(
        logStore: AnalyticsEventLogStore,
        consent: @escaping () -> AnalyticsConfig.ConsentLevel,
        provider: any AnalyticsDeliveryProvider,
        now: @escaping () -> Date = Date.init
    ) {
        self.logStore = logStore
        self.consent = consent
        self.provider = provider
        self.now = now
    }

    func reconcileConsent(level: AnalyticsConfig.ConsentLevel) {
        guard !hasReconciledConsent || level != appliedLevel else { return }
        let previousLevel = appliedLevel
        hasReconciledConsent = true
        appliedLevel = level

        if level == .off
            || (previousLevel == .productUsage && level == .errorReports)
        {
            provider.cancelInFlightRequests()
        }
    }

    func capture(_ input: AnalyticsEventInput) {
        capture(input, retryingAfterConsentChange: true)
    }

    func optIn(level: AnalyticsConfig.ConsentLevel) {
        guard level != .off, consent() == level else { return }
        reconcileConsent(level: level)
        capture(.consentChanged(to: level))
    }

    @discardableResult
    func optOut(deleteLocalState: Bool) -> Bool {
        hasReconciledConsent = true
        appliedLevel = .off
        provider.cancelInFlightRequests()
        guard deleteLocalState else { return true }
        let deletion = logStore.deleteAll()
        if deletion.distinctIDDeleted { cachedAnonymousID = nil }
        return deletion.succeeded
    }

    /// Deletes local transparency state and cancels active submissions while
    /// leaving the persisted consent choice unchanged. A request already in
    /// flight may still complete; the next accepted event uses a new ID only
    /// after deletion was confirmed.
    @discardableResult
    func deleteLocalAnalyticsState() -> Bool {
        provider.cancelInFlightRequests()
        let deletion = logStore.deleteAll()
        if deletion.distinctIDDeleted { cachedAnonymousID = nil }
        hasReconciledConsent = true
        appliedLevel = consent()
        return deletion.succeeded
    }

    /// Provider requests are resumed immediately and have no app-owned queue.
    /// Termination drains only the transparency ledger, whose completion the
    /// app can actually prove.
    func flushForTermination() {
        logStore.waitForPendingWrites()
    }

    private func capture(
        _ input: AnalyticsEventInput,
        retryingAfterConsentChange: Bool
    ) {
        let level = consent()
        guard level != .off else {
            reconcileConsent(level: .off)
            return
        }
        if level != appliedLevel || !hasReconciledConsent {
            reconcileConsent(level: level)
        }

        switch sanitizer.sanitize(input, consent: level) {
        case .dropped(let reason):
            append(
                input.intendedName,
                properties: [:],
                level: level,
                status: .dropped,
                reason: reason
            )

        case .event(let event):
            let timestamp = now()
            guard let anonymousID = stableAnonymousID() else {
                append(
                    event.name,
                    properties: event.properties,
                    level: level,
                    status: .failed,
                    reason: .deliveryUnavailable,
                    timestamp: timestamp
                )
                return
            }

            let dispatchLevel = consent()
            guard dispatchLevel == level else {
                reconcileConsent(level: dispatchLevel)
                if retryingAfterConsentChange {
                    capture(input, retryingAfterConsentChange: false)
                }
                return
            }

            switch provider.capture(
                event,
                anonymousID: anonymousID,
                timestamp: timestamp
            ) {
            case .submitted:
                append(
                    event.name,
                    properties: event.properties,
                    level: level,
                    status: .queued,
                    reason: nil,
                    timestamp: timestamp
                )
            case .rejected(let reason):
                append(
                    event.name,
                    properties: event.properties,
                    level: level,
                    status: reason == .rateLimited ? .dropped : .failed,
                    reason: reason,
                    timestamp: timestamp
                )
            }
        }
    }

    private func stableAnonymousID() -> UUID? {
        if let cachedAnonymousID { return cachedAnonymousID }
        guard let identifier = logStore.stableDistinctID() else { return nil }
        cachedAnonymousID = identifier
        return identifier
    }

    private func append(
        _ name: AnalyticsEventName,
        properties: [AnalyticsPropertyKey: AnalyticsPropertyValue],
        level: AnalyticsConfig.ConsentLevel,
        status: AnalyticsDeliveryStatus,
        reason: AnalyticsDropReason?,
        timestamp: Date? = nil
    ) {
        logStore.append(
            AnalyticsLogEntry(
                id: UUID(),
                timestamp: timestamp ?? now(),
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
