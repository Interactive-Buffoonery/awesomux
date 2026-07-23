import Foundation

/// Detects a wedged Ghostty event loop by correlating two signals: a
/// libghostty wakeup that has gone un-serviced by `ghostty_app_tick` for
/// too long, and a burst of fault-level `libxev_kqueue` log entries.
///
/// Staleness is measured from the oldest *pending wakeup*, never from
/// wall-clock tick age: an idle app produces no wakeups, so it can never
/// look stale, and the OSLog fault query — expensive enough to drive
/// OSLogService.xpc to hours of CPU when polled every few seconds on a
/// busy machine — only runs in the genuinely suspicious case where a
/// wakeup arrived and no tick followed. The detectable band is narrow
/// and deliberate: a queued tick Task that cannot run while this
/// watchdog's main-queue timer still can (a stuck coalescer latch, a
/// priority inversion pinning the Task). A fully blocked main thread
/// starves the timer too and is undetectable here, and a merely
/// backed-up main queue drains the older tick Task before the timer
/// fires. Neither signal alone fires the alert — a fault line doesn't
/// always mean a hang (mitchellh/libxev#122's own reporter saw it
/// recover sometimes). See Interactive-Buffoonery/awesomux#562 for the
/// incident this exists to catch.
@MainActor
final class GhosttyEventLoopWatchdog {
    static let staleWakeupThreshold: TimeInterval = 5
    static let faultWindow: TimeInterval = 30
    static let faultCountThreshold = 3

    private struct CheckRequest {
        var id: UInt64
        var generation: UInt64
        var since: Date
    }

    private let faultSource: any GhosttyFaultLogSource
    private let now: () -> Date
    private let pendingWakeupAge: () -> TimeInterval?
    private let onWedgeDetected: () -> Void
    private var generation: UInt64 = 0
    private var nextCheckID: UInt64 = 0
    private var activeCheckID: UInt64?
    private var hasFiredForCurrentStall = false
    private var checkTask: Task<Void, Never>?
    private var timer: DispatchSourceTimer?

    init(
        faultSource: any GhosttyFaultLogSource = OSLogGhosttyFaultSource(),
        now: @escaping () -> Date = Date.init,
        pendingWakeupAge: @escaping () -> TimeInterval?,
        onWedgeDetected: @escaping () -> Void
    ) {
        self.faultSource = faultSource
        self.now = now
        self.pendingWakeupAge = pendingWakeupAge
        self.onWedgeDetected = onWedgeDetected
    }

    /// Call on every successful `ghostty_app_tick`. The generation bump
    /// invalidates any in-flight fault query, and a serviced tick ends
    /// the current stall.
    func recordTick() {
        generation &+= 1
        hasFiredForCurrentStall = false
    }

    /// Testing seam only; exposes the tick generation so runtime wiring
    /// can assert tick() reaches the watchdog without OSLogStore/timers.
    var tickGenerationForTesting: UInt64 { generation }

    /// Exposed for deterministic policy tests. Production timer checks use the
    /// same begin/finish path without retaining the watchdog across a stalled
    /// OSLog query.
    @discardableResult
    func checkForWedge() async -> Bool {
        guard let request = beginCheck() else { return false }
        let faults = await faultSource.recentFaultCount(
            subsystem: "com.mitchellh.ghostty",
            category: "libxev_kqueue",
            since: request.since
        )
        guard !Task.isCancelled else {
            abandonCheck(request)
            return false
        }
        return finishCheck(request, faults: faults)
    }

    func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        // ponytail: 4s poll against a 5s staleWakeupThreshold / 30s
        // faultWindow — sub-5s granularity buys negligible detection
        // latency, and beginCheck no-ops without a pending wakeup, so
        // idle polls cost two lock acquisitions and no OSLog traffic.
        // No backoff while a stall persists: bounded at one query per
        // 4s and stalls are assumed rare; add backoff if sustained
        // stalls show up in the wild.
        timer.schedule(deadline: .now() + 4, repeating: 4)
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.startCheckIfNeeded()
            }
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
        checkTask?.cancel()
        checkTask = nil
        activeCheckID = nil
        generation &+= 1
    }

    private func startCheckIfNeeded() {
        guard checkTask == nil, let request = beginCheck() else { return }
        let faultSource = self.faultSource
        checkTask = Task { @MainActor [weak self] in
            let faults = await faultSource.recentFaultCount(
                subsystem: "com.mitchellh.ghostty",
                category: "libxev_kqueue",
                since: request.since
            )
            guard !Task.isCancelled else {
                self?.abandonCheck(request)
                return
            }
            _ = self?.finishCheck(request, faults: faults)
            self?.checkTask = nil
        }
    }

    private func beginCheck() -> CheckRequest? {
        guard !hasFiredForCurrentStall, activeCheckID == nil else { return nil }
        guard let age = pendingWakeupAge(), age >= Self.staleWakeupThreshold else {
            return nil
        }
        nextCheckID &+= 1
        activeCheckID = nextCheckID
        return CheckRequest(
            id: nextCheckID,
            generation: generation,
            since: now().addingTimeInterval(-Self.faultWindow)
        )
    }

    private func finishCheck(_ request: CheckRequest, faults: Int) -> Bool {
        guard activeCheckID == request.id else { return false }
        activeCheckID = nil
        // Re-read the live staleness signal, not just the generation
        // proxy: tick() clears the latch before its app guard, so a
        // wakeup can be serviced (pending nil) without recordTick ever
        // bumping the generation (app nil mid-reload).
        guard request.generation == generation,
            !hasFiredForCurrentStall,
            let age = pendingWakeupAge(), age >= Self.staleWakeupThreshold,
            faults >= Self.faultCountThreshold
        else {
            return false
        }
        hasFiredForCurrentStall = true
        onWedgeDetected()
        return true
    }

    private func abandonCheck(_ request: CheckRequest) {
        guard activeCheckID == request.id else { return }
        activeCheckID = nil
        checkTask = nil
    }
}
