import Foundation

/// Detects a wedged Ghostty event loop by correlating two signals:
/// staleness of the wakeup-driven `ghostty_app_tick` heartbeat, and a
/// burst of fault-level `libxev_kqueue` log entries. Neither signal
/// alone is reliable — a fault line doesn't always mean a hang
/// (mitchellh/libxev#122's own reporter saw it recover sometimes), and
/// tick silence alone is indistinguishable from a legitimately idle
/// app. See Interactive-Buffoonery/awesomux#562 for the incident this
/// exists to catch.
@MainActor
final class GhosttyEventLoopWatchdog {
    static let staleTickThreshold: TimeInterval = 5
    static let faultWindow: TimeInterval = 30
    static let faultCountThreshold = 3

    private struct CheckRequest {
        var id: UInt64
        var generation: UInt64
        var since: Date
    }

    private let faultSource: any GhosttyFaultLogSource
    private let now: () -> Date
    private let onWedgeDetected: () -> Void
    private var lastTickAt: Date
    private var generation: UInt64 = 0
    private var nextCheckID: UInt64 = 0
    private var activeCheckID: UInt64?
    private var hasFiredForCurrentStall = false
    private var checkTask: Task<Void, Never>?
    private var timer: DispatchSourceTimer?

    init(
        faultSource: any GhosttyFaultLogSource = OSLogGhosttyFaultSource(),
        now: @escaping () -> Date = Date.init,
        onWedgeDetected: @escaping () -> Void
    ) {
        self.faultSource = faultSource
        self.now = now
        self.onWedgeDetected = onWedgeDetected
        self.lastTickAt = now()
    }

    /// Call on every successful `ghostty_app_tick`.
    func recordTick() {
        lastTickAt = now()
        generation &+= 1
        hasFiredForCurrentStall = false
    }

    /// Testing seam only; exposes the heartbeat timestamp so wiring can be
    /// asserted without reaching into OSLogStore or timers.
    var lastTickAtForTesting: Date { lastTickAt }

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
        // ponytail: 4s poll against a 5s staleTickThreshold / 30s
        // faultWindow — sub-5s granularity buys negligible detection latency.
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
        let current = now()
        guard current.timeIntervalSince(lastTickAt) >= Self.staleTickThreshold else {
            return nil
        }
        nextCheckID &+= 1
        activeCheckID = nextCheckID
        return CheckRequest(
            id: nextCheckID,
            generation: generation,
            since: current.addingTimeInterval(-Self.faultWindow)
        )
    }

    private func finishCheck(_ request: CheckRequest, faults: Int) -> Bool {
        guard activeCheckID == request.id else { return false }
        activeCheckID = nil
        guard request.generation == generation,
            !hasFiredForCurrentStall,
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
