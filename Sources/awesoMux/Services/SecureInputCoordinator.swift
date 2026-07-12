import AppKit
import AwesoMuxCore
import Carbon
import Foundation
import os

@MainActor
final class SecureInputCoordinator {
    enum Mode: Equatable {
        case on
        case off
        case toggle
    }

    struct SystemCalls {
        let enable: () -> OSStatus
        let disable: () -> OSStatus

        @MainActor static let live = SystemCalls(
            enable: EnableSecureEventInput,
            disable: DisableSecureEventInput
        )
    }

    private static let logger = Logger(
        subsystem: "com.interactivebuffoonery.awesomux",
        category: "SecureInput"
    )

    private let systemCalls: SystemCalls
    private let notificationCenter: NotificationCenter?
    private var observerTokens: [NSObjectProtocol] = []
    private var requestingPaneIDs: Set<TerminalPane.ID> = []
    private var focusedPaneIDs: Set<TerminalPane.ID> = []
    private var isApplicationActive: Bool
    private(set) var isSystemEnabled = false

    init(
        systemCalls: SystemCalls = .live,
        notificationCenter: NotificationCenter? = .default,
        isApplicationActive: Bool = NSApp?.isActive ?? false
    ) {
        self.systemCalls = systemCalls
        self.notificationCenter = notificationCenter
        self.isApplicationActive = isApplicationActive

        guard let notificationCenter else { return }
        observerTokens = [
            notificationCenter.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.applicationDidBecomeActive()
                }
            },
            notificationCenter.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.applicationDidResignActive()
                }
            },
        ]
    }

    deinit {
        MainActor.assumeIsolated {
            for token in observerTokens {
                notificationCenter?.removeObserver(token)
            }
        }
    }

    func apply(_ mode: Mode, for paneID: TerminalPane.ID) {
        switch mode {
        case .on:
            requestingPaneIDs.insert(paneID)
        case .off:
            requestingPaneIDs.remove(paneID)
        case .toggle:
            if requestingPaneIDs.contains(paneID) {
                requestingPaneIDs.remove(paneID)
            } else {
                requestingPaneIDs.insert(paneID)
            }
        }
        reconcile()
    }

    func setFocused(_ focused: Bool, for paneID: TerminalPane.ID) {
        if focused {
            focusedPaneIDs.insert(paneID)
        } else {
            focusedPaneIDs.remove(paneID)
        }
        reconcile()
    }

    func removePane(_ paneID: TerminalPane.ID) {
        requestingPaneIDs.remove(paneID)
        focusedPaneIDs.remove(paneID)
        reconcile()
    }

    func reset() {
        requestingPaneIDs.removeAll()
        focusedPaneIDs.removeAll()
        reconcile()
    }

    func applicationDidBecomeActive() {
        isApplicationActive = true
        reconcile()
    }

    func applicationDidResignActive() {
        isApplicationActive = false
        reconcile()
    }

    private func reconcile() {
        let shouldEnable = isApplicationActive &&
            !requestingPaneIDs.isDisjoint(with: focusedPaneIDs)
        guard shouldEnable != isSystemEnabled else { return }

        let status = shouldEnable ? systemCalls.enable() : systemCalls.disable()
        guard status == noErr else {
            Self.logger.warning(
                "secure input apply failed enabled=\(shouldEnable, privacy: .public) status=\(status, privacy: .public)"
            )
            return
        }

        isSystemEnabled = shouldEnable
        Self.logger.debug("secure input enabled=\(shouldEnable, privacy: .public)")
    }
}
