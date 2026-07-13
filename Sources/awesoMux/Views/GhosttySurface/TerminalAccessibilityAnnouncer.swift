import AppKit
import AwesoMuxCore

@MainActor
enum TerminalAccessibilityAnnouncer {
    /// Tree-order pane descriptor (e.g. `"pane 2, web"`), spoken only when the
    /// session has multiple terminal panes so a VoiceOver user can tell which
    /// pane an announcement is about. The ordinal is the guaranteed
    /// discriminator (pane titles can be duplicated or blank by design); the
    /// title is appended when present. Mirrors the view-side
    /// `livePaneDescriptorForAnnouncement`, shared so the reconnect/disconnect
    /// announcements (which fire from the enactor and overlay, not that view
    /// extension) use the identical form (INT-697 fix #8).
    static func paneDescriptor(
        for paneID: TerminalPane.ID,
        in session: TerminalSession?
    ) -> String? {
        guard let session else { return nil }
        let panes = session.panes
        guard panes.count > 1,
              let index = panes.firstIndex(where: { $0.id == paneID }) else {
            return nil
        }
        let title = panes[index].title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "pane \(index + 1)" : "pane \(index + 1), \(title)"
    }
    /// Newline-strip + truncate to 60 characters with ellipsis, mirroring
    /// `AwesoMuxApp.compactTitle`. This helper only compacts for speech; it is
    /// NOT the bidi/control-character defense. Titles reaching the announcer
    /// come from the session store, which sanitizes at ingress via
    /// `SessionStoreText.sanitizedTitle` → `UnicodeHygiene.sanitize` (bidi
    /// overrides/isolates and control scalars stripped — pinned by
    /// `SessionStoreSanitizationTests.stripsBidiOverrides`). Kept here anyway
    /// so an overlong or multi-line title can't dominate a spoken string
    /// (INT-668).
    private static func compactTitle(_ raw: String) -> String {
        let oneLine = raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return oneLine.count > 60
            ? String(oneLine.prefix(60)) + "…"
            : oneLine
    }

    static func siblingPaneExitErrorAnnouncement(sessionTitle: String) -> String {
        let trimmed = compactTitle(sessionTitle).trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "Pane ended with an error."
        }
        return "Pane in \(trimmed) ended with an error."
    }

    static func workspaceClosedAfterProcessExitAnnouncement(
        exitedWithError: Bool
    ) -> String {
        if exitedWithError {
            return "Workspace closed. Terminal process ended with an error."
        }
        return "Workspace closed. Terminal process exited."
    }

    static func announceSiblingPaneExitError(sessionTitle: String) {
        post(
            siblingPaneExitErrorAnnouncement(sessionTitle: sessionTitle),
            priority: .medium
        )
    }

    static func announceWorkspaceClosedAfterProcessExit(exitedWithError: Bool) {
        // Route through `announce(...)` so the documented next-runloop-tick hop
        // (which keeps the announcement from being swallowed while a menu/drag is
        // tearing down) lives in exactly one place.
        announce(
            workspaceClosedAfterProcessExitAnnouncement(exitedWithError: exitedWithError),
            priority: .high
        )
    }

    static func announceShellRecycled() {
        post("New shell started.", priority: .high)
    }

    static func announceSessionRespawnedFresh() {
        post("Session restarted with a fresh shell.", priority: .medium)
    }

    /// Spoken when a remote pane's bridge dies and the reconnect overlay
    /// appears (INT-697). `host` names the dropped host; `paneDescriptor`
    /// disambiguates a split. The single voice for the disconnect transition —
    /// `markError` suppresses its generic "Session error." for this case.
    static func remoteDisconnectedAnnouncement(
        host: String,
        paneDescriptor: String? = nil,
        backgroundSessionsEnabled: Bool = true
    ) -> String {
        let pane = trimmedPaneDescriptor(paneDescriptor)
        if !backgroundSessionsEnabled {
            if let pane {
                return String(
                    localized: "Disconnected from \(host) in \(pane). Background sessions are off. Enable them to reconnect.",
                    comment:
                        "VoiceOver announcement when a managed SSH pane in a split is blocked because background terminal sessions are disabled"
                )
            }
            return String(
                localized: "Disconnected from \(host). Background sessions are off. Enable them to reconnect.",
                comment: "VoiceOver announcement when a managed SSH pane is blocked because background terminal sessions are disabled"
            )
        }
        if let pane {
            return String(
                localized: "Disconnected from \(host) in \(pane). Reconnect available.",
                comment: "VoiceOver announcement when a remote pane's SSH connection dies in a split, naming the host and pane"
            )
        }
        return String(
            localized: "Disconnected from \(host). Reconnect available.",
            comment: "VoiceOver announcement when a remote pane's SSH connection dies and a reconnect affordance appears"
        )
    }

    static func announceRemoteDisconnected(
        host: String,
        paneDescriptor: String? = nil,
        backgroundSessionsEnabled: Bool = true
    ) {
        post(
            remoteDisconnectedAnnouncement(
                host: host,
                paneDescriptor: paneDescriptor,
                backgroundSessionsEnabled: backgroundSessionsEnabled
            ),
            priority: .medium
        )
    }

    /// Spoken when a manual remote reconnect lands its `attached` confirmation
    /// (INT-697), the recovery counterpart to the disconnect announcement.
    /// `host` is nil when the pane had moved to a local group (a plain restart,
    /// no host to name) — success is still announced so it's never silent.
    static func announceRemoteReconnected(host: String?, paneDescriptor: String? = nil) {
        let pane = trimmedPaneDescriptor(paneDescriptor)
        let message: String
        switch (host, pane) {
        case let (host?, pane?):
            message = String(
                localized: "Reconnected to \(host) in \(pane).",
                comment: "VoiceOver announcement when a remote pane in a split reconnects, naming the host and pane"
            )
        case let (host?, nil):
            message = String(
                localized: "Reconnected to \(host).",
                comment: "VoiceOver announcement when a remote pane's SSH connection is re-established after a manual reconnect"
            )
        case let (nil, pane?):
            message = String(
                localized: "Reconnected in \(pane).",
                comment: "VoiceOver announcement when a moved-to-local pane in a split reconnects, with no host to name"
            )
        case (nil, nil):
            message = String(
                localized: "Reconnected.",
                comment: "VoiceOver announcement when a moved-to-local pane reconnects, with no host to name"
            )
        }
        post(message, priority: .medium)
    }

    private static func trimmedPaneDescriptor(_ descriptor: String?) -> String? {
        guard let trimmed = descriptor?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    /// `paneDescriptor` (e.g. `"pane 2, web"`) is passed only when the session
    /// is a split — two panes in one session would otherwise speak identical
    /// strings and a VoiceOver user couldn't tell which pane is ready. The
    /// descriptor carries a tree-order ordinal because pane titles can be
    /// duplicated (split clones the seed title) or blank by design
    /// (cross-model review, INT-419).
    static func waitingForInputAnnouncement(
        sessionTitle: String,
        paneDescriptor: String? = nil
    ) -> String {
        let session = compactTitle(sessionTitle).trimmingCharacters(in: .whitespacesAndNewlines)
        let pane = paneDescriptor.map(compactTitle)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch (session.isEmpty, pane.isEmpty) {
        case (true, true):
            return "Agent waiting for your input."
        case (false, true):
            return "Agent waiting for your input in \(session)."
        case (true, false):
            return "Agent waiting for your input in \(pane)."
        case (false, false):
            return "Agent waiting for your input in \(session), \(pane)."
        }
    }

    static func errorClearedAndWaitingForInputAnnouncement(
        sessionTitle: String,
        paneDescriptor: String? = nil
    ) -> String {
        "Session error cleared. " + waitingForInputAnnouncement(
            sessionTitle: sessionTitle,
            paneDescriptor: paneDescriptor
        )
    }

    /// `.high` priority is deliberate (INT-419): "agent ready for your input" is
    /// the transition the user is actively waiting on, unlike the passive
    /// error-entered/cleared signals which stay at `.medium`.
    static func announceWaitingForInput(sessionTitle: String, paneDescriptor: String? = nil) {
        post(
            waitingForInputAnnouncement(
                sessionTitle: sessionTitle,
                paneDescriptor: paneDescriptor
            ),
            priority: .high
        )
    }

    static func announceErrorClearedAndWaitingForInput(
        sessionTitle: String,
        paneDescriptor: String? = nil
    ) {
        post(
            errorClearedAndWaitingForInputAnnouncement(
                sessionTitle: sessionTitle,
                paneDescriptor: paneDescriptor
            ),
            priority: .high
        )
    }

    // MARK: - Remote permission prompts (INT-698)

    /// Prompt-arrival announcement — a remote agent is asking for authorization.
    /// Names the pane so a VoiceOver user knows *where*, and (per the spec's
    /// accessibility contract) is spoken because a prompt that surfaces silently
    /// as an attention badge is indistinguishable from one that never arrived.
    /// Pure builder; the caller posts it (or a test asserts on it) so the
    /// announcement seam stays injectable, matching `waitingForInputAnnouncement`.
    static func permissionPromptArrivedAnnouncement(
        sessionTitle: String,
        paneDescriptor: String? = nil
    ) -> String {
        permissionPromptAnnouncement(
            sessionTitle: sessionTitle,
            paneDescriptor: paneDescriptor,
            withPane: { pane in
                String(
                    localized: "Permission requested in \(pane).",
                    comment: "VoiceOver announcement when a remote agent asks for a permission decision in a named split pane"
                )
            },
            withSession: { session in
                String(
                    localized: "Permission requested in \(session).",
                    comment: "VoiceOver announcement when a remote agent asks for a permission decision, naming the workspace"
                )
            },
            plain: String(
                localized: "Permission requested.",
                comment: "VoiceOver announcement when a remote agent asks for a permission decision"
            )
        )
    }

    /// Timeout announcement — the local deadline fired and the prompt resolved as
    /// deny. Spoken so a silently-vanishing prompt is never mistaken for one that
    /// was answered.
    static func permissionPromptTimedOutAnnouncement(
        sessionTitle: String,
        paneDescriptor: String? = nil
    ) -> String {
        permissionPromptAnnouncement(
            sessionTitle: sessionTitle,
            paneDescriptor: paneDescriptor,
            withPane: { pane in
                String(
                    localized: "Permission request timed out in \(pane).",
                    comment: "VoiceOver announcement when a remote permission prompt expires (denied) in a named split pane"
                )
            },
            withSession: { session in
                String(
                    localized: "Permission request timed out in \(session).",
                    comment: "VoiceOver announcement when a remote permission prompt expires (denied), naming the workspace"
                )
            },
            plain: String(
                localized: "Permission request timed out.",
                comment: "VoiceOver announcement when a remote permission prompt expires and is denied"
            )
        )
    }

    /// Decision-confirmation announcement — the user's Allow/Deny went through
    /// (review finding: every other terminal state was announced except the
    /// success path, so a VoiceOver user activating Allow on the last prompt
    /// got total silence and had to guess whether it registered).
    static func permissionPromptDecidedAnnouncement(
        allowed: Bool,
        sessionTitle: String,
        paneDescriptor: String? = nil
    ) -> String {
        permissionPromptAnnouncement(
            sessionTitle: sessionTitle,
            paneDescriptor: paneDescriptor,
            withPane: { pane in
                allowed
                    ? String(
                        localized: "Permission granted in \(pane).",
                        comment: "VoiceOver announcement confirming the user allowed a remote permission request in a named split pane"
                    )
                    : String(
                        localized: "Permission denied in \(pane).",
                        comment: "VoiceOver announcement confirming the user denied a remote permission request in a named split pane"
                    )
            },
            withSession: { session in
                allowed
                    ? String(
                        localized: "Permission granted in \(session).",
                        comment: "VoiceOver announcement confirming the user allowed a remote permission request, naming the workspace"
                    )
                    : String(
                        localized: "Permission denied in \(session).",
                        comment: "VoiceOver announcement confirming the user denied a remote permission request, naming the workspace"
                    )
            },
            plain: allowed
                ? String(
                    localized: "Permission granted.",
                    comment: "VoiceOver announcement confirming the user allowed a remote permission request"
                )
                : String(
                    localized: "Permission denied.",
                    comment: "VoiceOver announcement confirming the user denied a remote permission request"
                )
        )
    }

    /// Cancellation announcement — the request reached a terminal state without
    /// a user decision (agent cancelled, connection lost, or backpressure
    /// overflow). Same silent-vanish rationale as the timeout announcement.
    static func permissionPromptCancelledAnnouncement(
        sessionTitle: String,
        paneDescriptor: String? = nil
    ) -> String {
        permissionPromptAnnouncement(
            sessionTitle: sessionTitle,
            paneDescriptor: paneDescriptor,
            withPane: { pane in
                String(
                    localized: "Permission request cancelled in \(pane).",
                    comment: "VoiceOver announcement when a remote permission prompt is cancelled in a named split pane"
                )
            },
            withSession: { session in
                String(
                    localized: "Permission request cancelled in \(session).",
                    comment: "VoiceOver announcement when a remote permission prompt is cancelled, naming the workspace"
                )
            },
            plain: String(
                localized: "Permission request cancelled.",
                comment: "VoiceOver announcement when a remote permission prompt is cancelled"
            )
        )
    }

    /// FIFO-advancement announcement — a queued prompt just became the active
    /// one, so a keyboard/VoiceOver user knows a new prompt is now reachable.
    static func permissionPromptAdvancedAnnouncement(
        sessionTitle: String,
        paneDescriptor: String? = nil
    ) -> String {
        permissionPromptAnnouncement(
            sessionTitle: sessionTitle,
            paneDescriptor: paneDescriptor,
            withPane: { pane in
                String(
                    localized: "Next permission request in \(pane).",
                    comment: "VoiceOver announcement when a queued remote permission prompt becomes active in a named split pane"
                )
            },
            withSession: { session in
                String(
                    localized: "Next permission request in \(session).",
                    comment: "VoiceOver announcement when a queued remote permission prompt becomes active, naming the workspace"
                )
            },
            plain: String(
                localized: "Next permission request.",
                comment: "VoiceOver announcement when a queued remote permission prompt becomes active"
            )
        )
    }

    /// Focus-move announcement (INT-698 addendum) — spoken when the
    /// `focusPermissionPrompt` palette command deliberately moves keyboard
    /// focus to the banner. The focus move itself is otherwise only
    /// perceivable visually (the contrasting focus ring); a VoiceOver user
    /// needs the same signal, and it also names the moment the keyboard-Allow
    /// mappings (⌘⏎ / A) become live.
    static func permissionPromptFocusedAnnouncement(
        sessionTitle: String,
        paneDescriptor: String? = nil
    ) -> String {
        permissionPromptAnnouncement(
            sessionTitle: sessionTitle,
            paneDescriptor: paneDescriptor,
            withPane: { pane in
                String(
                    localized: "Permission prompt focused in \(pane).",
                    comment: "VoiceOver announcement when the focus-permission-prompt command moves keyboard focus to a named split pane's remote permission banner"
                )
            },
            withSession: { session in
                String(
                    localized: "Permission prompt focused in \(session).",
                    comment: "VoiceOver announcement when the focus-permission-prompt command moves keyboard focus to the remote permission banner, naming the workspace"
                )
            },
            plain: String(
                localized: "Permission prompt focused.",
                comment: "VoiceOver announcement when the focus-permission-prompt command moves keyboard focus to the remote permission banner"
            )
        )
    }

    /// Shared shape for the permission announcements above: prefer the pane
    /// descriptor (a split), fall back to the workspace title, then to the bare
    /// sentence. Mirrors `waitingForInputAnnouncement`'s empty-vs-present logic
    /// and reuses `compactTitle` so an overlong title can't dominate speech.
    private static func permissionPromptAnnouncement(
        sessionTitle: String,
        paneDescriptor: String?,
        withPane: (String) -> String,
        withSession: (String) -> String,
        plain: String
    ) -> String {
        let pane = paneDescriptor.map(compactTitle)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !pane.isEmpty {
            return withPane(pane)
        }
        let session = compactTitle(sessionTitle).trimmingCharacters(in: .whitespacesAndNewlines)
        return session.isEmpty ? plain : withSession(session)
    }

    static func announceErrorEntered() {
        post("Session error.", priority: .medium)
    }

    static func announceErrorCleared() {
        post("Session error cleared.", priority: .medium)
    }

    static func announceErrorClearedAndShellRecycled() {
        post("Session error cleared. New shell started.", priority: .high)
    }

    /// Post a VoiceOver announcement, deferred to the next main-runloop tick.
    ///
    /// The async hop is load-bearing for menu- and drop-driven announcements:
    /// posting synchronously while a menu is still dismissing (or a drag session
    /// is tearing down) lets the announcement get swallowed by the system's own
    /// AX traffic. The single shared implementation used by the app commands and
    /// the pane drag/drop path so the two can't drift.
    static func announce(_ message: String, priority: NSAccessibilityPriorityLevel = .medium) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                post(message, priority: priority)
            }
        }
    }

    private static func post(_ message: String, priority: NSAccessibilityPriorityLevel) {
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: priority.rawValue
            ]
        )
    }
}
