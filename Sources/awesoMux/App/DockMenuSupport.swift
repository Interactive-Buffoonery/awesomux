import AppKit
import AwesoMuxCore

/// Boxes a `RecentlyClosedWorkspace` so it can ride on
/// `NSMenuItem.representedObject` (an Obj-C `id`) and be recovered by the reopen
/// action. It carries the whole snapshot because the store needs it to rebuild
/// the workspace; the store locates the row to consume by identity fields
/// `(sessionID, closedAt)`.
final class DockRecentWorkspaceToken: NSObject {
    let workspace: RecentlyClosedWorkspace

    init(workspace: RecentlyClosedWorkspace) {
        self.workspace = workspace
    }
}

/// Boxes an open workspace's session id so it can ride on
/// `NSMenuItem.representedObject` and be recovered by the Dock-menu
/// select action. Only the id is carried; the store resolves live state
/// (which may have changed since the menu was built) at click time.
final class DockOpenWorkspaceToken: NSObject {
    let sessionID: TerminalSession.ID

    init(sessionID: TerminalSession.ID) {
        self.sessionID = sessionID
    }
}

enum DockRecentWorkspaceMenu {
    /// Menu label for a recently-closed workspace. Falls back to a generic label
    /// when the captured title is blank so the row is never an empty click
    /// target.
    static func displayTitle(
        for workspace: RecentlyClosedWorkspace,
        bundle: Bundle = .main,
        locale: Locale = .current
    ) -> String {
        displayTitle(forWorkspaceTitle: workspace.localizedTitle(
            bundle: bundle,
            locale: locale
        ))
    }

    /// A live workspace as it appears in the Dock menu's open-workspaces
    /// section: sanitized label, its session id, and whether it's the
    /// currently-selected workspace (checkmark).
    struct OpenWorkspaceRow: Equatable {
        let sessionID: TerminalSession.ID
        let title: String
        let isActive: Bool
    }

    /// Flattens open workspaces to Dock-menu rows in sidebar order (pinned
    /// first, then groups in order, sessions within) — the same order the
    /// ⌘-jump shortcuts use. Titles are sanitized; the active workspace is
    /// marked. Pure so the ordering / sanitization / empty-store behavior is
    /// unit-testable without an AppKit menu.
    static func openWorkspaceRows(
        groups: [SessionGroup],
        pinnedSessionIDs: [TerminalSession.ID],
        activeID: TerminalSession.ID?
    ) -> [OpenWorkspaceRow] {
        let sessionsByID = Dictionary(
            groups.flatMap(\.sessions).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let orderedIDs = WorkspaceNavigationOrder.pinnedFirstSessionIDs(
            in: groups,
            pinnedSessionIDs: pinnedSessionIDs
        )
        return orderedIDs.compactMap { id in
            sessionsByID[id].map { session in
                OpenWorkspaceRow(
                    sessionID: session.id,
                    title: displayTitle(forWorkspaceTitle: session.title),
                    isActive: session.id == activeID
                )
            }
        }
    }

    /// Menu label for a live (open) workspace, sharing the recently-closed
    /// sanitizer + blank fallback so both Dock sections read identically.
    static func displayTitle(forWorkspaceTitle rawTitle: String) -> String {
        // Stored/live titles are not sanitized at rest — the reopen path
        // sanitizes them. A menu is a display surface too, so run the same
        // canonical sanitizer (keeps LRM/RLM hints, drops RLO/LRO overrides,
        // caps length).
        let sanitized = SessionStore.sanitizedTitle(rawTitle)
        let trimmed = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return String(
                localized: "Untitled Workspace",
                comment: "Dock menu label for a workspace that has no title."
            )
        }
        return trimmed
    }
}
