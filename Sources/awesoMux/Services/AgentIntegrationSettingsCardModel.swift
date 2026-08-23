import AwesoMuxConfig
import Foundation

/// Injectable delay seam so debounce/retry timing is deterministic in tests.
protocol AgentIntegrationSettingsSleeping: Sendable {
    func delay(for duration: Duration) async throws
}

struct ContinuousDelayClock: AgentIntegrationSettingsSleeping {
    private let clock = ContinuousClock()

    func delay(for duration: Duration) async throws {
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
///
/// Each provider observes through its own probe-service instance (vended by
/// the injected factory), so one provider's stuck probe cannot serialize every
/// other provider's behind it on a shared serial executor. A probe that does
/// stick is bounded by a watchdog: after `defaultProbeTimeout` the model
/// publishes an authoritative `.timedOut` card instead of waiting forever.
/// The watchdog only stops the UI waiting on the result — the blocked actor
/// task itself keeps running until its I/O returns.
@Observable
@MainActor
final class AgentIntegrationSettingsCardModel {
    private(set) var cardStates: [AgentIntegrationInstallProvider: AgentIntegrationSettingsCardState] = [:]
    /// The setup each published card was derived from. A draft that no longer
    /// matches downgrades the card to advisory (`isAuthoritative` false), so a
    /// stale Install affordance can never be acted on during a debounce window.
    private var cardInputs: [AgentIntegrationInstallProvider: AgentIntegrationSetup] = [:]
    /// The setup each running probe was launched for. Tracked separately from
    /// `cardInputs`, which only updates on publication, so an in-flight probe
    /// can satisfy a duplicate request without lying about what is published.
    private var inFlightSetups: [AgentIntegrationInstallProvider: AgentIntegrationSetup] = [:]
    /// Set while a scheduled draft validation has not produced a publication
    /// yet; the displayed path validations describe the previous input during
    /// that window and say so.
    private var pendingValidations: [AgentIntegrationInstallProvider: Bool] = [:]

    private let viewModel: AgentIntegrationSettingsViewModel
    private let makeProbeService: @Sendable (AgentIntegrationInstallProvider) -> any AgentIntegrationProbing
    private var probeServices: [AgentIntegrationInstallProvider: any AgentIntegrationProbing] = [:]
    private let clock: any AgentIntegrationSettingsSleeping
    private let validationDebounce: Duration
    private let transientRetryDelay: Duration
    private let probeTimeout: Duration

    private var generations: [AgentIntegrationInstallProvider: Int] = [:]
    private var probeTasks: [AgentIntegrationInstallProvider: Task<Void, Never>] = [:]
    private var watchdogTasks: [AgentIntegrationInstallProvider: Task<Void, Never>] = [:]
    private var debounceTasks: [AgentIntegrationInstallProvider: Task<Void, Never>] = [:]
    private var retryTasks: [AgentIntegrationInstallProvider: Task<Void, Never>] = [:]
    /// Set while a `.busy` observation is awaiting its single bounded retry;
    /// cleared by any non-transient publication or explicit refresh. Prevents
    /// one lock collision from caching a durable "blocked".
    private var retryingTransient: [AgentIntegrationInstallProvider: Bool] = [:]

    /// The happy-path probe is sub-millisecond local stat/read work, so a probe
    /// only ever hits this bound on genuinely stuck I/O: an unresponsive
    /// network share, a stale automount, or an unreadable special file.
    static let defaultProbeTimeout: Duration = .seconds(5)

    init(
        viewModel: AgentIntegrationSettingsViewModel,
        probeServices: @escaping @Sendable (AgentIntegrationInstallProvider) -> any AgentIntegrationProbing,
        clock: any AgentIntegrationSettingsSleeping = ContinuousDelayClock(),
        validationDebounce: Duration = .milliseconds(250),
        transientRetryDelay: Duration = .milliseconds(500),
        probeTimeout: Duration = AgentIntegrationSettingsCardModel.defaultProbeTimeout
    ) {
        self.viewModel = viewModel
        self.makeProbeService = probeServices
        self.clock = clock
        self.validationDebounce = validationDebounce
        self.transientRetryDelay = transientRetryDelay
        self.probeTimeout = probeTimeout
    }

    /// The stored state for a provider, or a layout-stable placeholder when no
    /// observation has landed yet. Never nil, so cards are present from the
    /// first body evaluation. A stored observation whose input no longer
    /// matches — or whose authority was explicitly withdrawn after a file
    /// mutation — keeps its visible content but renders unauthoritative.
    func state(for provider: AgentIntegrationInstallProvider, setup: AgentIntegrationSetup)
        -> AgentIntegrationSettingsCardState
    {
        guard let state = cardStates[provider] else {
            var placeholder = viewModel.placeholderCardState(provider: provider, setup: setup)
            placeholder.isValidating = pendingValidations[provider] ?? false
            return placeholder
        }
        var resolved = state
        if let input = cardInputs[provider], input != setup {
            // Observations no longer match the current draft: keep the visible
            // content stable but withdraw action authorization.
            resolved.isAuthoritative = false
        }
        resolved.isValidating = pendingValidations[provider] ?? false
        return resolved
    }

    /// Re-observe one provider. Routine triggers are collapsed: when the exact
    /// setup is already published-authoritative or has a probe in flight, this
    /// is a duplicate of work already happening and is skipped. Lifecycle
    /// triggers pass `forcing: true` — an unchanged setup says nothing about
    /// unchanged files, so appear/refocus must always re-stat.
    func refresh(
        provider: AgentIntegrationInstallProvider,
        setup: AgentIntegrationSetup,
        forcing: Bool = false
    ) {
        if !forcing, isAlreadyObservedOrInFlight(provider: provider, setup: setup) {
            return
        }
        startProbe(provider: provider, setup: setup)
    }

    func refreshAll(
        setupsByProvider: [AgentIntegrationInstallProvider: AgentIntegrationSetup],
        forcing: Bool = false
    ) {
        for (provider, setup) in setupsByProvider {
            refresh(provider: provider, setup: setup, forcing: forcing)
        }
    }

    /// Withdraws published authority for a provider without touching its cached
    /// observation. File mutations (install/uninstall) change what disk holds
    /// but not the setup, so the next probe must confirm the new reality before
    /// action affordances act on the pre-mutation snapshot.
    func invalidateObservation(provider: AgentIntegrationInstallProvider) {
        cardStates[provider]?.isAuthoritative = false
    }

    /// Draft edits land here per keystroke. Collapses bursts into one probe
    /// after the debounce window; each reschedule cancels the previous wait.
    func scheduleDraftValidation(provider: AgentIntegrationInstallProvider, setup: AgentIntegrationSetup) {
        debounceTasks[provider]?.cancel()
        pendingValidations[provider] = true
        let generationAtSchedule = currentGeneration(provider)
        debounceTasks[provider] = Task { @MainActor in
            try? await clock.delay(for: validationDebounce)
            guard !Task.isCancelled else { return }
            // Superseded by an explicit refresh since scheduling? Then the
            // refresh's own probe already covers the newer input.
            // A provider that has never probed has no stored generation yet;
            // both sides must read through the same defaulted lookup.
            // A newer generation alone does not imply coverage: a transient
            // retry also raises the generation while re-probing an older
            // setup, and that must not swallow this validation.
            if generations[provider, default: 0] != generationAtSchedule,
                cardInputs[provider] == setup
            {
                return
            }
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
        for task in watchdogTasks.values {
            task.cancel()
        }
        watchdogTasks.removeAll()
        for task in retryTasks.values {
            task.cancel()
        }
        retryTasks.removeAll()
        pendingValidations.removeAll()
        inFlightSetups.removeAll()
    }

    // MARK: - Probe plumbing

    private func currentGeneration(_ provider: AgentIntegrationInstallProvider) -> Int {
        generations[provider, default: 0]
    }

    /// True when an identical observation is already in flight or already backs
    /// the published card, so routine triggers (the store-write echo into
    /// `refreshAll`, a targeted refresh after commit) do not fan out redundant
    /// probes for every provider on every user action.
    private func isAlreadyObservedOrInFlight(
        provider: AgentIntegrationInstallProvider,
        setup: AgentIntegrationSetup
    ) -> Bool {
        if inFlightSetups[provider] == setup {
            return true
        }
        if cardInputs[provider] == setup, cardStates[provider]?.isAuthoritative == true {
            return true
        }
        return false
    }

    private func probeService(for provider: AgentIntegrationInstallProvider) -> any AgentIntegrationProbing {
        if let service = probeServices[provider] {
            return service
        }
        let service = makeProbeService(provider)
        probeServices[provider] = service
        return service
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
            retryTasks[provider]?.cancel()
            retryTasks[provider] = nil
        }
        probeTasks[provider]?.cancel()
        watchdogTasks[provider]?.cancel()
        inFlightSetups[provider] = setup
        let service = probeService(for: provider)
        probeTasks[provider] = Task { @MainActor in
            let probe = await service.probe(provider: provider, setup: setup)
            guard !Task.isCancelled else { return }
            apply(probe, provider: provider, setup: setup, generation: generation)
        }
        scheduleWatchdog(provider: provider, setup: setup, generation: generation)
    }

    /// Internal (not private) so the generation-guard test can drive a stale
    /// publication directly — reaching this path through `startProbe` always
    /// involves cancellation, which would mask the guard under test.
    func apply(
        _ probe: AgentIntegrationProviderProbe,
        provider: AgentIntegrationInstallProvider,
        setup: AgentIntegrationSetup,
        generation: Int
    ) {
        guard generations[provider] == generation else { return }

        // Any publication supersedes the pending watchdog and the in-flight
        // marker for this attempt.
        watchdogTasks[provider]?.cancel()
        watchdogTasks[provider] = nil
        inFlightSetups[provider] = nil
        pendingValidations[provider] = false

        cardStates[provider] = viewModel.cardState(provider: provider, setup: setup, probe: probe)
        cardInputs[provider] = setup

        let transient = isTransient(probe.manifest)
        if transient && !(retryingTransient[provider] ?? false) {
            retryingTransient[provider] = true
            scheduleTransientRetry(provider: provider, setup: setup, generation: generation)
        } else if !transient {
            retryingTransient[provider] = false
        }
    }

    private func isTransient(_ observation: AgentIntegrationManifestObservation) -> Bool {
        observation == .busy
    }

    /// Bounds one probe attempt. Fires only if the same generation is still
    /// current; a completed probe cancels this task via `apply`, and a newer
    /// probe bumps the generation so a late watchdog stands down. Publishing a
    /// timeout does not free the blocked probe task — it only stops the card
    /// waiting on it.
    /// Known ceiling: this bounds how long the UI waits, not the probe itself.
    /// `probe` has no suspension point, so a call already executing inside its
    /// actor cannot be cancelled or reclaimed — a timeout publishes an honest
    /// status while that work keeps running, and repeated triggers against a
    /// genuinely hung path queue behind it. Per-provider actors keep that
    /// contained to the offending provider; making it fully recoverable needs
    /// the blocking filesystem calls moved off the actor onto an executor it
    /// awaits, which is a larger change than this one.
    private func scheduleWatchdog(
        provider: AgentIntegrationInstallProvider,
        setup: AgentIntegrationSetup,
        generation: Int
    ) {
        watchdogTasks[provider] = Task { @MainActor in
            try? await clock.delay(for: probeTimeout)
            guard !Task.isCancelled else { return }
            guard generations[provider, default: 0] == generation else { return }
            publishTimedOut(provider: provider, setup: setup, generation: generation)
        }
    }

    private func publishTimedOut(
        provider: AgentIntegrationInstallProvider,
        setup: AgentIntegrationSetup,
        generation: Int
    ) {
        guard generations[provider] == generation else { return }
        watchdogTasks[provider] = nil
        inFlightSetups[provider] = nil
        pendingValidations[provider] = false

        // The placeholder skeleton is filesystem-free and layout-stable; only
        // the status and authority change: we did look, and the look failed.
        var timedOut = viewModel.placeholderCardState(provider: provider, setup: setup)
        timedOut.status = .timedOut
        timedOut.isAuthoritative = true
        cardStates[provider] = timedOut
        cardInputs[provider] = setup
    }

    private func scheduleTransientRetry(
        provider: AgentIntegrationInstallProvider,
        setup: AgentIntegrationSetup,
        generation: Int
    ) {
        let task = Task { @MainActor in
            try? await clock.delay(for: transientRetryDelay)
            guard !Task.isCancelled else { return }
            guard generations[provider, default: 0] == generation else { return }
            startProbe(provider: provider, setup: setup, isTransientRetry: true)
        }
        retryTasks[provider] = task
    }
}
