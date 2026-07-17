import AppKit
import AwesoMuxCore
import Foundation
import os

@MainActor
final class WindowOrderDiagnostics {
    static let environmentKey = "AWESOMUX_WINDOW_ORDER_DIAGNOSTICS"

    private static let logger = Logger(
        subsystem: "com.interactivebuffoonery.awesomux",
        category: "WindowOrderDiagnostics"
    )

    static let isEnabled = enabled(in: ProcessInfo.processInfo.environment)

    private let notificationCenter: NotificationCenter
    private var observations: [NSObjectProtocol] = []
    private var lastUpdateSnapshot: WindowSnapshot?

    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
    }

    static func enabled(in environment: [String: String]) -> Bool {
        environment[environmentKey] == "1"
    }

    func start() {
        guard Self.isEnabled, observations.isEmpty else { return }

        Self.logApplication(event: "diagnostics-start")

        observeApplicationNotification(NSApplication.didBecomeActiveNotification, event: "app-did-become-active")
        observeApplicationNotification(NSApplication.didResignActiveNotification, event: "app-did-resign-active")
        observeApplicationUpdates()

        let windowEvents: [(Notification.Name, String)] = [
            (NSWindow.didBecomeKeyNotification, "window-did-become-key"),
            (NSWindow.didResignKeyNotification, "window-did-resign-key"),
            (NSWindow.didBecomeMainNotification, "window-did-become-main"),
            (NSWindow.didResignMainNotification, "window-did-resign-main"),
            (NSWindow.didMiniaturizeNotification, "window-did-miniaturize"),
            (NSWindow.didDeminiaturizeNotification, "window-did-deminiaturize"),
            (NSWindow.didChangeOcclusionStateNotification, "window-occlusion-changed"),
            (.awesoMuxWindowRoleDidChange, "window-role-changed"),
        ]
        for (name, event) in windowEvents {
            observeWindowNotification(name, event: event)
        }
    }

    func stop() {
        for observation in observations {
            notificationCenter.removeObserver(observation)
        }
        observations.removeAll()
        lastUpdateSnapshot = nil
    }

    static func logSurfacePrimaryWindow(
        event: String,
        caller: StaticString,
        fileID: StaticString,
        line: UInt
    ) {
        guard isEnabled else { return }

        log(
            event: event,
            window: NSApp.windows.first(where: { $0.isAwesoMuxPrimaryContentWindow }),
            caller: String(describing: caller),
            fileID: String(describing: fileID),
            line: line
        )
    }

    static func logApplicationReopen(hasVisibleWindows: Bool) {
        guard isEnabled else { return }

        log(
            event: hasVisibleWindows
                ? "application-should-handle-reopen-visible"
                : "application-should-handle-reopen-no-visible",
            window: NSApp.windows.first(where: { $0.isAwesoMuxPrimaryContentWindow })
        )
    }

    static func logRoster(event: String, open: Bool, displayMode: SidebarWidthMode) {
        guard isEnabled else { return }

        let displayModeName =
            switch displayMode {
            case .expanded: "expanded"
            case .collapsed: "collapsed"
            }
        logger.info(
            "window-order event=\(event, privacy: .public) rosterOpen=\(open, privacy: .public) sidebarDisplayMode=\(displayModeName, privacy: .public) appActive=\(NSApp.isActive, privacy: .public)"
        )
    }

    static func logSidebarPresentation(
        event: String,
        userWantsHidden: Bool,
        isVisible: Bool,
        proximity: SidebarPresentationModel.ProximityState,
        source: SidebarVisibilitySource
    ) {
        guard isEnabled else { return }

        logger.info(
            "window-order event=\(event, privacy: .public) sidebarUserWantsHidden=\(userWantsHidden, privacy: .public) sidebarVisible=\(isVisible, privacy: .public) sidebarProximity=\(String(describing: proximity), privacy: .public) sidebarSource=\(String(describing: source), privacy: .public) appActive=\(NSApp.isActive, privacy: .public)"
        )
    }

    private func observeApplicationNotification(_ name: Notification.Name, event: String) {
        observations.append(
            notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    Self.logApplication(event: event)
                    DispatchQueue.main.async {
                        Self.logApplication(event: "\(event)-settled")
                    }
                }
            })
    }

    private func observeWindowNotification(_ name: Notification.Name, event: String) {
        observations.append(
            notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { notification in
                nonisolated(unsafe) let notification = notification
                MainActor.assumeIsolated {
                    guard let window = notification.object as? NSWindow,
                        window.isAwesoMuxPrimaryContentWindow
                    else { return }
                    Self.log(event: event, window: window)
                }
            })
    }

    private func observeApplicationUpdates() {
        lastUpdateSnapshot = Self.currentWindowSnapshot()
        observations.append(
            notificationCenter.addObserver(
                forName: NSApplication.didUpdateNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let snapshot = Self.currentWindowSnapshot()
                    guard snapshot != self.lastUpdateSnapshot else { return }
                    self.lastUpdateSnapshot = snapshot
                    Self.logApplication(event: "app-update-window-state-changed")
                }
            })
    }

    private static func logApplication(event: String) {
        guard isEnabled else { return }

        log(
            event: event,
            window: NSApp.windows.first(where: { $0.isAwesoMuxPrimaryContentWindow })
        )
    }

    private static func log(
        event: String,
        window: NSWindow?,
        caller: String = "none",
        fileID: String = "none",
        line: UInt = 0
    ) {
        let frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"
        let eventType = NSApp.currentEvent.map { String($0.type.rawValue) } ?? "none"
        let eventModifiers = NSApp.currentEvent.map { String($0.modifierFlags.rawValue) } ?? "none"
        let windowNumber = window?.windowNumber ?? -1
        let isVisible = window?.isVisible ?? false
        let isKey = window?.isKeyWindow ?? false
        let isMain = window?.isMainWindow ?? false
        let isMiniaturized = window?.isMiniaturized ?? false
        let occlusionState = window?.occlusionState.rawValue ?? 0
        let level = window?.level.rawValue ?? 0
        let orderedIndex =
            window.flatMap { target in
                NSApp.orderedWindows.firstIndex(where: { $0 === target })
            } ?? -1

        logger.info(
            "window-order event=\(event, privacy: .public) appActive=\(NSApp.isActive, privacy: .public) frontmostBundleID=\(frontmostBundleID, privacy: .public) windowNumber=\(windowNumber, privacy: .public) visible=\(isVisible, privacy: .public) key=\(isKey, privacy: .public) main=\(isMain, privacy: .public) miniaturized=\(isMiniaturized, privacy: .public) occlusion=\(occlusionState, privacy: .public) level=\(level, privacy: .public) orderedIndex=\(orderedIndex, privacy: .public) currentEventType=\(eventType, privacy: .public) currentEventModifiers=\(eventModifiers, privacy: .public) caller=\(caller, privacy: .public) fileID=\(fileID, privacy: .public) line=\(line, privacy: .public)"
        )
    }

    private static func currentWindowSnapshot() -> WindowSnapshot {
        let window = NSApp.windows.first(where: { $0.isAwesoMuxPrimaryContentWindow })
        return WindowSnapshot(
            appIsActive: NSApp.isActive,
            frontmostBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            windowNumber: window?.windowNumber,
            isVisible: window?.isVisible ?? false,
            isKey: window?.isKeyWindow ?? false,
            isMain: window?.isMainWindow ?? false,
            isMiniaturized: window?.isMiniaturized ?? false,
            occlusionState: window?.occlusionState.rawValue ?? 0,
            level: window?.level.rawValue ?? 0,
            orderedIndex: window.flatMap { target in
                NSApp.orderedWindows.firstIndex(where: { $0 === target })
            }
        )
    }

    private struct WindowSnapshot: Equatable {
        let appIsActive: Bool
        let frontmostBundleID: String?
        let windowNumber: Int?
        let isVisible: Bool
        let isKey: Bool
        let isMain: Bool
        let isMiniaturized: Bool
        let occlusionState: UInt
        let level: Int
        let orderedIndex: Int?
    }
}
