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

    private let faultSource: GhosttyFaultLogSource
    private let now: () -> Date
    private let onWedgeDetected: () -> Void
    private var lastTickAt: Date
    private var hasFiredForCurrentStall = false
    private var timer: DispatchSourceTimer?

    init(
        faultSource: GhosttyFaultLogSource = OSLogGhosttyFaultSource(),
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
        hasFiredForCurrentStall = false
    }

    /// Testing seam only; exposes the heartbeat timestamp so wiring can be
    /// asserted without reaching into OSLogStore or timers.
    var lastTickAtForTesting: Date { lastTickAt }

    /// Exposed for testing; `start()` calls this on a timer in production.
    @discardableResult
    func checkForWedge() -> Bool {
        guard !hasFiredForCurrentStall else { return false }
        let current = now()
        guard current.timeIntervalSince(lastTickAt) >= Self.staleTickThreshold else {
            return false
        }
        let faults = faultSource.recentFaultCount(
            subsystem: "com.mitchellh.ghostty",
            category: "libxev_kqueue",
            since: current.addingTimeInterval(-Self.faultWindow)
        )
        guard faults >= Self.faultCountThreshold else { return false }

        hasFiredForCurrentStall = true
        onWedgeDetected()
        return true
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        // ponytail: 4s poll against a 5s staleTickThreshold / 30s
        // faultWindow — sub-5s granularity buys negligible detection
        // latency but was firing a disk-backed OSLogStore query every
        // single second while idle.
        timer.schedule(deadline: .now() + 4, repeating: 4)
        // Compiler infers this closure as @MainActor-isolated because it's
        // created directly inside this @MainActor method (SE-0306 closure
        // isolation inference), so `checkForWedge()` type-checks without
        // `await`. That inference alone wouldn't guarantee runtime safety —
        // but MainActor's default executor IS DispatchQueue.main, and this
        // timer is scheduled on `queue: .main`, so the handler genuinely
        // runs on the main actor's executor, not just a same-named queue.
        timer.setEventHandler { [weak self] in
            self?.checkForWedge()
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }
}
