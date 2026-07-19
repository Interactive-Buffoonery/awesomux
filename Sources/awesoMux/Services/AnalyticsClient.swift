import AwesoMuxConfig
import Foundation

/// Seam between capture sites and the analytics provider. Feature code
/// never talks to an analytics transport directly (ADR-0008): it submits
/// closed `AnalyticsEventInput` values, and the client owns consent
/// gating, sanitization, local logging, and eventual provider delivery.
@MainActor
protocol AnalyticsClient: AnyObject {
    /// Reconciles provider lifecycle with the persisted setting at launch and
    /// after every config reload. The client also reads the live level again
    /// immediately before each submission.
    func reconcileConsent(level: AnalyticsConfig.ConsentLevel)
    func capture(_ input: AnalyticsEventInput)
    func optIn(level: AnalyticsConfig.ConsentLevel)
    @discardableResult func optOut(deleteLocalState: Bool) -> Bool
}
