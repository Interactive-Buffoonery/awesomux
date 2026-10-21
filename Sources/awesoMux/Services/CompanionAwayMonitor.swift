import AppKit
import AwesoMuxCore
import Foundation

/// Serializes console/lock signals with the journal's main-actor writes.
@MainActor
final class CompanionAwayMonitor {
    // The owner writes on the main actor; notification removal is thread-safe.
    private final class Observations: @unchecked Sendable {
        var tokens: [(NotificationCenter, NSObjectProtocol)] = []
        deinit {
            for (center, token) in tokens { center.removeObserver(token) }
        }
    }

    private weak var store: SessionStore?
    private let observations = Observations()
    private var locked: Bool
    private var onConsole: Bool
    private var isAway: Bool { locked || !onConsole }

    init(store: SessionStore) {
        self.store = store
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        locked = session?["CGSSessionScreenIsLocked"] as? Bool ?? false
        onConsole = session?[kCGSessionOnConsoleKey as String] as? Bool ?? false
        if isAway { store.beginCompanionAwayPeriod() }
        observe(DistributedNotificationCenter.default(), name: .init("com.apple.screenIsLocked")) { monitor in
            monitor.transition { monitor.locked = true }
        }
        observe(DistributedNotificationCenter.default(), name: .init("com.apple.screenIsUnlocked")) { monitor in
            monitor.transition { monitor.locked = false }
        }
        observe(NSWorkspace.shared.notificationCenter, name: NSWorkspace.sessionDidResignActiveNotification) { monitor in
            monitor.transition { monitor.onConsole = false }
        }
        observe(NSWorkspace.shared.notificationCenter, name: NSWorkspace.sessionDidBecomeActiveNotification) { monitor in
            monitor.transition { monitor.onConsole = true }
        }
        observe(NotificationCenter.default, name: NSApplication.didBecomeActiveNotification) { monitor in
            monitor.presentIfReady()
        }
    }

    func recordAuthenticatedActivity() {
        // Requests can reach the main actor before a queued lock/return signal.
        // Reconcile the live console state before qualifying this interval.
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
            let onConsole = session[kCGSessionOnConsoleKey as String] as? Bool
        else { return }
        transition {
            self.onConsole = onConsole
            locked = session["CGSSessionScreenIsLocked"] as? Bool ?? false
        }
        store?.recordAuthenticatedCompanionActivity()
    }

    private func observe(
        _ center: NotificationCenter, name: Notification.Name,
        action: @escaping @MainActor (CompanionAwayMonitor) -> Void
    ) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                action(self)
            }
        }
        observations.tokens.append((center, token))
    }

    private func transition(_ update: () -> Void) {
        let wasAway = isAway
        update()
        if !wasAway, isAway { store?.beginCompanionAwayPeriod() }
        if wasAway, !isAway { store?.endCompanionAwayPeriod() }
        presentIfReady()
    }

    private func presentIfReady() {
        guard !isAway, NSApp.isActive else { return }
        store?.presentWhileAwaySummaryIfReady()
    }
}
