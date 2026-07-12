import AwesoMuxCore
import Foundation
import Observation

struct DiagnosticsPresentation: Equatable, Sendable {
    let revision: UUID
    let processSnapshot: DiagnosticsProcessSnapshot?
    let history: DiagnosticsHistory
    let events: LocalDiagnosticEventSnapshot
    let checkedAt: Date?

    static let empty = DiagnosticsPresentation(
        revision: UUID(),
        processSnapshot: nil,
        history: DiagnosticsHistory(),
        events: LocalDiagnosticEventSnapshot(events: []),
        checkedAt: nil
    )
}

enum DiagnosticsRefreshState: Equatable, Sendable {
    case idle
    case refreshing
    case partial
    case failed(lastSuccess: Date?)
}

@MainActor
@Observable
final class DiagnosticsModel {
    /// Capture is invoked from a MainActor-bound coordinator. Heavy work hops
    /// via nonisolated `DiagnosticsProcessCapture` / `AmxBackend` across `await`.
    /// Injected test closures may touch MainActor state.
    typealias Capture = (
        _ owners: [TerminalSessionID: DiagnosticsSessionOwner],
        _ date: Date,
        _ purpose: DiagnosticsCapturePurpose
    ) async -> DiagnosticsCaptureResult?

    /// Re-run `amx list` on every Nth successful timed sample to refresh ownership.
    static let daemonRediscoverySampleInterval = 5

    private(set) var presentation: DiagnosticsPresentation = .empty
    private(set) var refreshState: DiagnosticsRefreshState = .idle

    @ObservationIgnored private let sessionStore: SessionStore
    @ObservationIgnored private let eventRecorder: LocalDiagnosticEventRecorder
    @ObservationIgnored private let capture: Capture
    @ObservationIgnored private let sampleInterval: Duration
    @ObservationIgnored private let sampleTolerance: Duration
    @ObservationIgnored private var history = DiagnosticsHistory()
    @ObservationIgnored private var latestProcessSnapshot: DiagnosticsProcessSnapshot?
    @ObservationIgnored private var knownDaemons: [LiveDaemon] = []
    /// Last successful `amx list` availability (false after partial list failure).
    @ObservationIgnored private var lastDaemonListAvailable = true
    @ObservationIgnored private var successfulSampleCount = 0
    @ObservationIgnored private var samplingRequested = false
    @ObservationIgnored private var samplingTask: Task<Void, Never>?
    /// Producer Task for the current capture (cancellable).
    @ObservationIgnored private var captureTask: Task<DiagnosticsCaptureResult?, Never>?
    /// Completes only after MainActor apply — joiners wait on this, not the producer alone.
    @ObservationIgnored private var committedCapture: Task<DiagnosticsCaptureResult?, Never>?
    @ObservationIgnored private var capturePurpose: DiagnosticsCapturePurpose?
    @ObservationIgnored private var captureGeneration = 0

    init(
        sessionStore: SessionStore,
        eventRecorder: LocalDiagnosticEventRecorder,
        sampleInterval: Duration = .seconds(30),
        sampleTolerance: Duration = .seconds(3),
        capture: Capture? = nil
    ) {
        self.sessionStore = sessionStore
        self.eventRecorder = eventRecorder
        self.sampleInterval = sampleInterval
        self.sampleTolerance = sampleTolerance
        self.capture = capture ?? { owners, date, purpose in
            await DiagnosticsProcessCapture.capture(
                owners: owners,
                at: date,
                purpose: purpose
            )
        }
    }

    // MARK: - Sampling lifecycle

    func startSampling() {
        samplingRequested = true
        publishEventsOnly()
        // Pane-visible maintenance always runs: prune/republish events even before
        // the first process refresh; switch to process samples once a snapshot exists.
        scheduleMaintenanceIfNeeded()
    }

    func stopSampling() {
        samplingRequested = false
        samplingTask?.cancel()
        samplingTask = nil
        if capturePurpose?.isSample == true {
            captureTask?.cancel()
        }
    }

    private func scheduleMaintenanceIfNeeded() {
        guard samplingRequested, samplingTask == nil else { return }
        let interval = sampleInterval
        let tolerance = sampleTolerance
        samplingTask = Task { @MainActor [weak self] in
            let clock = ContinuousClock()
            var nextTick = clock.now.advanced(by: interval)
            while !Task.isCancelled {
                do {
                    try await clock.sleep(until: nextTick, tolerance: tolerance)
                } catch {
                    return
                }
                guard let self, self.samplingRequested else { return }
                if self.latestProcessSnapshot != nil {
                    await self.sampleOnce()
                } else {
                    self.eventRecorder.removeExpiredEvents()
                    self.publishEventsOnly()
                }
                nextTick = nextTick.advanced(by: interval)
                while nextTick <= clock.now {
                    nextTick = nextTick.advanced(by: interval)
                }
            }
        }
    }

    /// After a successful refresh, restart the cadence so the first timed sample
    /// is ~interval from that refresh (not from an earlier events-only open).
    private func restartMaintenanceIfRequested() {
        samplingTask?.cancel()
        samplingTask = nil
        scheduleMaintenanceIfNeeded()
    }

    // MARK: - Capture actions

    func refresh() async {
        guard refreshState != .refreshing else { return }
        refreshState = .refreshing
        let outcome = await captureAndStore(
            at: Date(),
            purpose: .refresh(fallbackDaemons: knownDaemons)
        )
        let now = Date()
        // Superseded by a newer capture — do not clobber its presentation.
        guard outcome.generation == captureGeneration else { return }
        guard let result = outcome.result else {
            eventRecorder.record(.processSamplingFailed, at: now)
            publishFailedRefresh()
            refreshState = .failed(lastSuccess: presentation.checkedAt)
            return
        }

        lastDaemonListAvailable = result.snapshot.daemonListAvailable
        publish(checkedAt: now)
        refreshState = result.snapshot.daemonListAvailable ? .idle : .partial
        restartMaintenanceIfRequested()
    }

    func sampleOnce(at date: Date = Date()) async {
        eventRecorder.removeExpiredEvents(at: date)
        let nextIndex = successfulSampleCount + 1
        let rediscover = nextIndex % Self.daemonRediscoverySampleInterval == 0
        let purpose = DiagnosticsCapturePurpose.sample(
            knownDaemons: knownDaemons,
            rediscoverDaemons: rediscover,
            daemonListAvailable: lastDaemonListAvailable
        )
        let ownedCapture = committedCapture == nil
        let outcome = await captureAndStore(at: date, purpose: purpose)
        // Joiners never apply post-await side effects — the owner (or a
        // superseding refresh) publishes committed state.
        guard ownedCapture else { return }
        // If a newer capture generation committed after our flight finished,
        // skip stale sample effects (Codex residual: sample A overwriting refresh B).
        guard outcome.generation == captureGeneration else { return }
        if let result = outcome.result {
            successfulSampleCount = nextIndex
            lastDaemonListAvailable = result.snapshot.daemonListAvailable
            publish(checkedAt: result.snapshot.collectedAt)
            applySampleRefreshState(daemonListAvailable: result.snapshot.daemonListAvailable)
        } else {
            // Keep process snapshot/history/freshness; refresh events after prune/cancel.
            publishEventsOnly()
        }
    }

    /// Keeps banners honest after timed samples: list unavailable ⇒ partial;
    /// list available clears failed/partial to idle.
    private func applySampleRefreshState(daemonListAvailable: Bool) {
        if daemonListAvailable {
            switch refreshState {
            case .failed, .partial:
                refreshState = .idle
            case .idle, .refreshing:
                break
            }
        } else {
            switch refreshState {
            case .failed, .idle:
                refreshState = .partial
            case .partial, .refreshing:
                break
            }
        }
    }

    isolated deinit {
        samplingTask?.cancel()
        captureTask?.cancel()
        committedCapture?.cancel()
    }

    // MARK: - Capture coordination

    private struct CaptureOutcome: Sendable {
        let result: DiagnosticsCaptureResult?
        /// Generation that produced (or was joined for) this outcome.
        let generation: Int
    }

    private func captureAndStore(
        at date: Date,
        purpose: DiagnosticsCapturePurpose
    ) async -> CaptureOutcome {
        if let committedCapture {
            let inFlightPurpose = capturePurpose
            let inFlightGeneration = captureGeneration
            let result = await committedCapture.value
            if purpose.isRefresh, inFlightPurpose?.isRefresh != true {
                return await beginCapture(at: date, purpose: purpose)
            }
            return CaptureOutcome(result: result, generation: inFlightGeneration)
        }
        return await beginCapture(at: date, purpose: purpose)
    }

    private func beginCapture(
        at date: Date,
        purpose: DiagnosticsCapturePurpose
    ) async -> CaptureOutcome {
        let owners = sessionOwners()
        let capture = capture
        captureGeneration += 1
        let generation = captureGeneration
        capturePurpose = purpose

        // MainActor-bound coordinator Task; heavy work hops off via nonisolated capture.
        let producer = Task<DiagnosticsCaptureResult?, Never> { @MainActor in
            let result = await capture(owners, date, purpose)
            guard !Task.isCancelled else { return nil }
            return result
        }
        captureTask = producer

        let flight = Task<DiagnosticsCaptureResult?, Never> { @MainActor in
            let result = await producer.value
            let accepted = producer.isCancelled ? nil : result
            // Generation gate: a superseded capture must not apply or report success.
            guard generation == captureGeneration else { return nil }
            if let accepted {
                latestProcessSnapshot = accepted.snapshot
                history.append(accepted.snapshot)
                if let discoveredDaemons = accepted.discoveredDaemons {
                    knownDaemons = discoveredDaemons
                }
            }
            if generation == captureGeneration {
                captureTask = nil
                capturePurpose = nil
                committedCapture = nil
            }
            return accepted
        }
        committedCapture = flight
        let result = await flight.value
        return CaptureOutcome(result: result, generation: generation)
    }

    // MARK: - Presentation

    private func publish(checkedAt: Date?) {
        presentation = DiagnosticsPresentation(
            revision: UUID(),
            processSnapshot: latestProcessSnapshot,
            history: history,
            events: eventRecorder.snapshot(),
            checkedAt: checkedAt
        )
    }

    private func publishFailedRefresh() {
        presentation = DiagnosticsPresentation(
            revision: UUID(),
            processSnapshot: presentation.processSnapshot,
            history: presentation.history,
            events: eventRecorder.snapshot(),
            checkedAt: presentation.checkedAt
        )
    }

    /// Surfaces events recorded this launch without inventing process data.
    private func publishEventsOnly() {
        presentation = DiagnosticsPresentation(
            revision: UUID(),
            processSnapshot: latestProcessSnapshot,
            history: history,
            events: eventRecorder.snapshot(),
            checkedAt: presentation.checkedAt
        )
    }

    // MARK: - Session ownership

    private func sessionOwners() -> [TerminalSessionID: DiagnosticsSessionOwner] {
        var owners: [TerminalSessionID: DiagnosticsSessionOwner] = [:]
        for group in sessionStore.groups {
            for session in group.sessions {
                session.layout.forEachPane { pane in
                    owners[pane.terminalSessionID] = DiagnosticsSessionOwner(
                        sessionTitle: session.title,
                        paneTitle: pane.title,
                        isSelected: session.id == sessionStore.selectedSessionID
                    )
                }
            }
        }
        return owners
    }
}
