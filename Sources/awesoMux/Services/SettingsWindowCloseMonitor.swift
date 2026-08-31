import AppKit

/// Reports closure of the specific Settings window captured from SwiftUI.
///
/// A `Window` scene can retain its view tree after its `NSWindow` closes, so
/// view disappearance is not a reliable close signal. Observing the resolved
/// window keeps the callback tied to the native lifecycle instead.
@MainActor
final class SettingsWindowCloseMonitor {
    private let notificationCenter: NotificationCenter
    private let onClose: () -> Void
    private var observation: NSObjectProtocol?

    init(
        notificationCenter: NotificationCenter = .default,
        onClose: @escaping () -> Void
    ) {
        self.notificationCenter = notificationCenter
        self.onClose = onClose
    }

    func observe(_ window: NSWindow?) {
        if let observation {
            notificationCenter.removeObserver(observation)
            self.observation = nil
        }

        guard let window else { return }
        observation = notificationCenter.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.onClose()
            }
        }
    }

    isolated deinit {
        if let observation {
            notificationCenter.removeObserver(observation)
        }
    }
}
