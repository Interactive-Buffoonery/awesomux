import Foundation

enum AnalyticsProviderCaptureResult: Equatable, Sendable {
    case submitted
    case rejected(AnalyticsDropReason)
}

/// Provider boundary beneath the app-owned analytics policy pipeline.
/// Implementations receive only sanitized, typed events.
@MainActor
protocol AnalyticsDeliveryProvider: AnyObject {
    /// Starts one best-effort submission. `submitted` means only that the
    /// request was created and resumed, not that PostHog ingested it.
    func capture(
        _ event: SanitizedAnalyticsEvent,
        anonymousID: UUID,
        timestamp: Date
    ) -> AnalyticsProviderCaptureResult

    /// Cancels requests that have not completed. A request already in flight
    /// may still reach the provider, so user-facing copy must not promise
    /// retroactive deletion.
    func cancelInFlightRequests()
}
