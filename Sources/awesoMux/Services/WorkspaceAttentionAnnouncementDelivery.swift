import AppKit
import AwesoMuxCore
import Foundation

@MainActor
enum WorkspaceAttentionAnnouncementDelivery {
    static func deliver(
        _ announcements: [WorkspaceAttentionAnnouncementTracker.Announcement],
        bundle: Bundle = .main,
        locale: Locale = .current
    ) {
        deliver(announcements, bundle: bundle, locale: locale) { message in
            NSAccessibility.post(
                element: NSApplication.shared,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: message,
                    .priority: NSAccessibilityPriorityLevel.medium.rawValue
                ]
            )
        }
    }

    @discardableResult
    static func deliver(
        _ announcements: [WorkspaceAttentionAnnouncementTracker.Announcement],
        bundle: Bundle,
        locale: Locale,
        post: (String) -> Void
    ) -> String? {
        guard let message = WorkspaceAttentionAnnouncementTracker.spokenAnnouncement(
            for: announcements,
            bundle: bundle,
            locale: locale
        ) else {
            return nil
        }
        post(message)
        return message
    }
}
