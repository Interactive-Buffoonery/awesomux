import AwesoMuxConfig
import Foundation

/// Seam between capture sites and the analytics provider. Feature code
/// never talks to an analytics SDK directly (ADR-0008): it submits
/// closed `AnalyticsEventInput` values, and the client owns consent
/// gating, sanitization, local logging, and eventual provider delivery.
@MainActor
protocol AnalyticsClient: AnyObject {
    /// Reconciles provider lifecycle with the persisted setting at launch and
    /// after every config reload. Provider implementations must also read the
    /// live level again before dispatching queued work.
    func reconcileConsent(level: AnalyticsConfig.ConsentLevel)
    func capture(_ input: AnalyticsEventInput)
    func optIn(level: AnalyticsConfig.ConsentLevel)
    @discardableResult func optOut(deleteLocalState: Bool) -> Bool
}
