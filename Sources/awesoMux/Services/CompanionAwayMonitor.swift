import AppKit
import AwesoMuxCore
import Foundation

/// Reconciles console state on the same actor as journal writes.
@MainActor
final class CompanionAwayMonitor {
    private final class SignalObserver: NSObject, @unchecked Sendable {
        let action: @MainActor () -> Void
        init(action: @escaping @MainActor () -> Void) { self.action = action }
        @objc func receive(_ notification: Notification) {
            Task { @MainActor [weak self] in self?.action() }
        }
    }

    private final class Observations: @unchecked Sendable {
        var tokens: [(NotificationCenter, NSObjectProtocol)] = []
        deinit {
            for (center, token) in tokens { center.removeObserver(token) }
        }
    }

    private weak var store: SessionStore?
    private let observations = Observations()
    private let consoleIsAway: @MainActor () -> Bool?
    private let appIsActive: @MainActor () -> Bool
    private var isAway = false

    init(
        store: SessionStore,
        consoleIsAway: @escaping @MainActor () -> Bool? = CompanionAwayMonitor.currentConsoleIsAway,
        appIsActive: @escaping @MainActor () -> Bool = { NSApp?.isActive == true }
    ) {
        self.store = store
        self.consoleIsAway = consoleIsAway
        self.appIsActive = appIsActive
        store.reconcileCompanionAwayState = { [weak self] in self?.reconcile() }
        reconcile()
        let distributed = DistributedNotificationCenter.default()
        let observer = SignalObserver { [weak self] in self?.reconcile() }
        for name in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
            distributed.addObserver(
                observer, selector: #selector(SignalObserver.receive(_:)),
                name: .init(name), object: nil, suspensionBehavior: .deliverImmediately)
        }
        observations.tokens.append((distributed, observer))
        observe(NSWorkspace.shared.notificationCenter, name: NSWorkspace.sessionDidResignActiveNotification)
        observe(NSWorkspace.shared.notificationCenter, name: NSWorkspace.sessionDidBecomeActiveNotification)
        observe(NotificationCenter.default, name: NSApplication.didBecomeActiveNotification)
    }

    private static func currentConsoleIsAway() -> Bool? {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
            let onConsole = session[kCGSessionOnConsoleKey as String] as? Bool
        else { return nil }
        return !onConsole || (session["CGSSessionScreenIsLocked"] as? Bool ?? false)
    }

    func recordAuthenticatedActivity() {
        guard reconcile() else { return }
        store?.recordAuthenticatedCompanionActivity()
    }

    private func observe(_ center: NotificationCenter, name: Notification.Name) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile() }
        }
        observations.tokens.append((center, token))
    }

    @discardableResult
    func reconcile() -> Bool {
        // Notifications are wakeups, never state: an old queued signal must not
        // reverse a newer console sample. Failed samples preserve the interval.
        guard let away = consoleIsAway() else { return false }
        let wasAway = isAway
        isAway = away
        if !wasAway, isAway { store?.beginCompanionAwayPeriod() }
        if wasAway, !isAway { store?.endCompanionAwayPeriod() }
        if !isAway, appIsActive() { store?.presentWhileAwaySummaryIfReady() }
        return true
    }
}
