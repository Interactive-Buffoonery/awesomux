import AwesoMuxConfig
import Observation

/// App-lifetime consent observation independent of any SwiftUI window scene.
/// External config reloads must stop delivery even when every window is closed.
@MainActor
@Observable
final class AnalyticsConsentObserver {
    @ObservationIgnored private let settings: AppSettingsStore
    @ObservationIgnored private let client: any AnalyticsClient
    @ObservationIgnored private let reconcileRetention: (Bool) -> Void
    @ObservationIgnored private var isStarted = false

    init(
        settings: AppSettingsStore,
        client: any AnalyticsClient,
        reconcileRetention: @escaping (Bool) -> Void = { _ in }
    ) {
        self.settings = settings
        self.client = client
        self.reconcileRetention = reconcileRetention
    }

    static func effectiveConsent(
        for settings: AppSettingsStore
    ) -> AnalyticsConfig.ConsentLevel {
        settings.isDiskConfigInvalid ? .off : settings.analytics.value.consentLevel
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        observeCurrentConsent()
    }

    private func observeCurrentConsent() {
        let state = withObservationTracking {
            (
                consent: Self.effectiveConsent(for: settings),
                retainsLocalLog: settings.analytics.value.retainLocalEventLog
            )
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard self?.isStarted == true else { return }
                self?.observeCurrentConsent()
            }
        }
        client.reconcileConsent(level: state.consent)
        reconcileRetention(state.retainsLocalLog)
    }
}
