import AwesoMuxConfig
import Foundation

/// Injectable delay seam so debounce/retry timing is deterministic in tests.
protocol AgentIntegrationSettingsSleeping: Sendable {
    func sleep(for duration: Duration) async throws
}

struct ContinuousDelayClock: AgentIntegrationSettingsSleeping {
    private let clock = ContinuousClock()

    func sleep(for duration: Duration) async throws {
        try await clock.sleep(for: duration)
    }
}

/// Owns the cached integration card states for the Agents settings pane.
///
/// All observation happens off-main through `AgentIntegrationProbing`; this
/// model only publishes. Publication is generation-guarded: every run captures
/// the provider's generation at start and applies only if it still matches,
/// so a slow older probe (or a stale debounced validation) can never overwrite
/// a newer result — task cancellation alone cannot guarantee that, because
/// synchronous filesystem work does not observe cancellation.
@Observable
@MainActor
final class AgentIntegrationSettingsCardModel {
    private(set) var cardStates: [AgentIntegrationInstallProvider: AgentIntegrationSettingsCardState] = [:]

    private let viewModel: AgentIntegrationSettingsViewModel
    private let probeService: any AgentIntegrationProbing
    private let clock: any AgentIntegrationSettingsSleeping
    private let validationDebounce: Duration
    private let transientRetryDelay: Duration

    private var generations: [AgentIntegrationInstallProvider: Int] = [:]
    private var probeTasks: [AgentIntegrationInstallProvider: Task<Void, Never>] = [:]
    private var debounceTasks: [AgentIntegrationInstallProvider: Task<Void, Never>] = [:]
    /// Set while a `.busy`/`.unavailable` observation is awaiting its single
    /// bounded retry; cleared by any non-transient publication or explicit
    /// refresh. Prevents one lock collision from caching a durable "blocked".
    private var retryingTransient: [AgentIntegrationInstallProvider: Bool] = [:]

    init(
        viewModel: AgentIntegrationSettingsViewModel,
        probeService: any AgentIntegrationProbing,
        clock: any AgentIntegrationSettingsSleeping = ContinuousDelayClock(),
        validationDebounce: Duration = .milliseconds(250),
        transientRetryDelay: Duration = .milliseconds(500)
    ) {
        self.viewModel = viewModel
        self.probeService = probeService
        self.clock = clock
        self.validationDebounce = validationDebounce
        self.transientRetryDelay = transientRetryDelay
    }

    /// The stored state for a provider, or a layout-stable placeholder when no
    /// authoritative observation has landed yet. Never nil, so cards are present
    /// from the first body evaluation.
    func state(for provider: AgentIntegrationInstallProvider, setup: AgentIntegrationSetup)
        -> AgentIntegrationSettingsCardState
    {
        if let state = cardStates[provider], state.isAuthoritative {
            return state
        }
        return viewModel.placeholderCardState(provider: provider, setup: setup)
    }

    func refresh(provider: AgentIntegrationInstallProvider, setup: AgentIntegrationSetup) {
        startProbe(provider: provider, setup: setup)
    }

    func refreshAll(setupsByProvider: [AgentIntegrationInstallProvider: AgentIntegrationSetup]) {
        for (provider, setup) in setupsByProvider {
            refresh(provider: provider, setup: setup)
        }
    }

    /// Draft edits land here per keystroke. Collapses bursts into one probe
    /// after the debounce window; each reschedule cancels the previous wait.
    func scheduleDraftValidation(provider: AgentIntegrationInstallProvider, setup: AgentIntegrationSetup) {
        debounceTasks[provider]?.cancel()
        guard !Task.isCancelled else { return }
        let generationAtSchedule = currentGeneration(provider)
        debounceTasks[provider] = Task { @MainActor in
            try? await clock.sleep(for: validationDebounce)
            guard !Task.isCancelled else { return }
            // Superseded by an explicit refresh since scheduling? Then the
            // refresh's own probe already covers the newer input.
            // A provider that has never probed has no stored generation yet;
            // both sides must read through the same defaulted lookup.
            guard generations[provider, default: 0] == generationAtSchedule else { return }
            startProbe(provider: provider, setup: setup)
        }
    }

    func cancelPendingWork() {
        for task in debounceTasks.values {
            task.cancel()
        }
        debounceTasks.removeAll()
        for task in probeTasks.values {
            task.cancel()
        }
        probeTasks.removeAll()
    }

    // MARK: - Probe plumbing

    private func currentGeneration(_ provider: AgentIntegrationInstallProvider) -> Int {
        generations[provider, default: 0]
    }

    private func startProbe(
        provider: AgentIntegrationInstallProvider,
        setup: AgentIntegrationSetup,
        isTransientRetry: Bool = false
    ) {
        debounceTasks[provider]?.cancel()
        debounceTasks[provider] = nil
        generations[provider, default: 0] += 1
        let generation = generations[provider]!
        // An explicit trigger clears the retry latch; a scheduled retry keeps it
        // set so one busy observation retries exactly once instead of looping.
        if !isTransientRetry {
            retryingTransient[provider] = false
        }
        probeTasks[provider]?.cancel()
        probeTasks[provider] = Task { @MainActor in
            let probe = await probeService.probe(provider: provider, setup: setup)
            guard !Task.isCancelled else { return }
            apply(probe, provider: provider, setup: setup, generation: generation)
        }
    }

    private func apply(
        _ probe: AgentIntegrationProviderProbe,
        provider: AgentIntegrationInstallProvider,
        setup: AgentIntegrationSetup,
        generation: Int
    ) {
        guard generations[provider] == generation else { return }

        cardStates[provider] = viewModel.cardState(provider: provider, setup: setup, probe: probe)

        let transient = isTransient(probe.manifest)
        if transient && !(retryingTransient[provider] ?? false) {
            retryingTransient[provider] = true
            scheduleTransientRetry(provider: provider, setup: setup, generation: generation)
        } else if !transient {
            retryingTransient[provider] = false
        }
    }

    private func isTransient(_ observation: AgentIntegrationManifestObservation) -> Bool {
        observation == .busy || observation == .unavailable
    }

    private func scheduleTransientRetry(
        provider: AgentIntegrationInstallProvider,
        setup: AgentIntegrationSetup,
        generation: Int
    ) {
        Task { @MainActor in
            try? await clock.sleep(for: transientRetryDelay)
            guard !Task.isCancelled else { return }
            guard generations[provider] == generation else { return }
            startProbe(provider: provider, setup: setup, isTransientRetry: true)
        }
    }
}
