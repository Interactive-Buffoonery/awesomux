import AppKit
import Foundation
import Observation
@preconcurrency import UserNotifications

/// Observable macOS notification-authorization state for Settings →
/// Notifications (INT-598 gap 1). Read-only mirror of the system state: it
/// never requests authorization itself — macOS shows the permission dialog at
/// most once per app, so a denied state is only fixable in System Settings,
/// and re-prompt loops are exactly what this surface exists to avoid.
///
/// The status → copy mapping and the System Settings deep link are pure
/// static helpers so they stay unit-testable without touching
/// `UNUserNotificationCenter` (which requires a real app bundle).
@MainActor
@Observable
final class NotificationAuthorizationModel {
    /// Product-level projection of `UNAuthorizationStatus`. `.provisional` /
    /// `.ephemeral` collapse onto `.authorized` — both deliver notifications,
    /// and the settings pane only needs "working / blocked / not asked yet".
    enum DisplayStatus: Equatable {
        /// Not yet queried (first render before the async settings fetch lands).
        case unknown
        case notDetermined
        case authorized
        case denied
    }

    private(set) var status: DisplayStatus = .unknown

    @ObservationIgnored private let statusProvider:
        (@escaping @MainActor (UNAuthorizationStatus) -> Void) -> Void

    init(
        statusProvider: (
            (@escaping @MainActor (UNAuthorizationStatus) -> Void) -> Void
        )? = nil
    ) {
        self.statusProvider = statusProvider ?? { completion in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                Task { @MainActor in
                    completion(settings.authorizationStatus)
                }
            }
        }
    }

    /// Re-query the system authorization state. Called on pane appear and on
    /// app re-activation, so a user who flips the toggle in System Settings
    /// and comes back sees the fresh state without relaunching.
    func refresh() {
        statusProvider { [weak self] rawStatus in
            self?.status = Self.displayStatus(for: rawStatus)
        }
    }

    /// Deep link into System Settings → Notifications for this app, so a
    /// denied user can fix the permission without hunting for the pane.
    func openSystemNotificationSettings() {
        guard let url = Self.systemNotificationSettingsURL(
            bundleIdentifier: Bundle.main.bundleIdentifier
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    nonisolated static func displayStatus(for status: UNAuthorizationStatus) -> DisplayStatus {
        switch status {
        case .authorized, .provisional:
            .authorized
        case .denied:
            .denied
        case .notDetermined:
            .notDetermined
        // `.ephemeral` is iOS-only (unavailable on macOS), so it falls into
        // the unknown branch by construction rather than by intent.
        @unknown default:
            .unknown
        }
    }

    /// `x-apple.systempreferences` link to the per-app Notifications pane.
    /// Falls back to the top-level Notifications pane when the bundle ID is
    /// unavailable (e.g. a bare `swift run` binary outside an .app wrapper).
    nonisolated static func systemNotificationSettingsURL(bundleIdentifier: String?) -> URL? {
        let base = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else {
            return URL(string: base)
        }
        return URL(string: "\(base)?id=\(bundleIdentifier)")
    }
}
