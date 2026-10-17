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
    private let invalidateRemoteConnectivityEvidence: @MainActor () -> Void
    private let pathMonitorFactory: () -> any ConnectivityPathMonitoring
    private let pathsAreEqual: (NWPath, NWPath) -> Bool
    private let pathMonitorQueue = DispatchQueue(
        label: "com.interactivebuffoonery.awesomux.remote-connectivity"
    )

    private var wakeObserver: NSObjectProtocol?
    private var pathMonitor: (any ConnectivityPathMonitoring)?
    private var lastPath: NWPath?

    init(
        notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        pathMonitorFactory: @escaping () -> any ConnectivityPathMonitoring = { NWPathMonitor() },
        pathsAreEqual: @escaping (NWPath, NWPath) -> Bool = (==),
        invalidateRemoteConnectivityEvidence: @escaping @MainActor () -> Void
    ) {
        self.notificationCenter = notificationCenter
        self.pathMonitorFactory = pathMonitorFactory
        self.pathsAreEqual = pathsAreEqual
        self.invalidateRemoteConnectivityEvidence = invalidateRemoteConnectivityEvidence
    }

    isolated deinit {
        stop()
    }

    func start() {
        guard wakeObserver == nil, pathMonitor == nil else {
            return
        }

        lastPath = nil
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
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.recordPathMonitorUpdate(path)
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
        lastPath = nil
    }

    func recordPathMonitorUpdate(_ path: NWPath) {
        guard let lastPath else {
            self.lastPath = path
            return
        }
        guard !pathsAreEqual(lastPath, path) else { return }

        self.lastPath = path
        recordConnectivitySignal()
    }

    func recordConnectivitySignal() {
        invalidateRemoteConnectivityEvidence()
    }
}
