import AppKit
import Foundation
import Network

@MainActor
protocol ConnectivityPathMonitoring: AnyObject {
    var pathUpdateHandler: (@Sendable (NWPath) -> Void)? { get set }

    func start(queue: DispatchQueue)
    func cancel()
}

extension NWPathMonitor: ConnectivityPathMonitoring {}

@MainActor
final class RemoteConnectivityObserver {
    private let notificationCenter: NotificationCenter
    private let debounceNanoseconds: UInt64
    private let markRemotePanesPossiblyStale: @MainActor () -> Void
    private let pathMonitorFactory: () -> any ConnectivityPathMonitoring
    /// Seam for the debounce wait (INT-557): tests inject a controllable gate so
    /// the timer "elapses" on command instead of racing real wall-clock sleeps
    /// under parallel test scheduling. Production uses the real sleep default.
    private let sleep: @Sendable (Duration) async -> Void
    private let pathMonitorQueue = DispatchQueue(
        label: "com.interactivebuffoonery.awesomux.remote-connectivity"
    )

    private var wakeObserver: NSObjectProtocol?
    private var pathMonitor: (any ConnectivityPathMonitoring)?
    private var debounceTask: Task<Void, Never>?
    private var hasSeenInitialPathUpdate = false

    init(
        notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        debounceNanoseconds: UInt64 = 1_000_000_000,
        pathMonitorFactory: @escaping () -> any ConnectivityPathMonitoring = { NWPathMonitor() },
        sleep: @Sendable @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        markRemotePanesPossiblyStale: @escaping @MainActor () -> Void
    ) {
        self.notificationCenter = notificationCenter
        self.debounceNanoseconds = debounceNanoseconds
        self.pathMonitorFactory = pathMonitorFactory
        self.sleep = sleep
        self.markRemotePanesPossiblyStale = markRemotePanesPossiblyStale
    }

    isolated deinit {
        stop()
    }

    func start() {
        guard wakeObserver == nil, pathMonitor == nil else {
            return
        }

        hasSeenInitialPathUpdate = false
        wakeObserver = notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.recordConnectivitySignal()
            }
        }

        let monitor = pathMonitorFactory()
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in
                self?.recordPathMonitorUpdate()
            }
        }
        monitor.start(queue: pathMonitorQueue)
        pathMonitor = monitor
    }

    func stop() {
        if let wakeObserver {
            notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }

        pathMonitor?.cancel()
        pathMonitor = nil
        debounceTask?.cancel()
        debounceTask = nil
        hasSeenInitialPathUpdate = false
    }

    func recordPathMonitorUpdate() {
        guard hasSeenInitialPathUpdate else {
            hasSeenInitialPathUpdate = true
            return
        }

        recordConnectivitySignal()
    }

    func recordConnectivitySignal() {
        debounceTask?.cancel()
        // Captures by value, no self: the pending task must not keep the
        // observer alive (deinit cancels it), and a cancelled sleep falls
        // through to the isCancelled guard rather than marking.
        debounceTask = Task { [sleep, debounceNanoseconds, markRemotePanesPossiblyStale] in
            // Clamping is deliberate: Duration wants Int64, and a debounce
            // anywhere near Int64.max nanoseconds (~292 years) is already
            // "never" — saturating beats trapping.
            await sleep(.nanoseconds(Int64(clamping: debounceNanoseconds)))
            guard !Task.isCancelled else {
                return
            }
            markRemotePanesPossiblyStale()
        }
    }
}
