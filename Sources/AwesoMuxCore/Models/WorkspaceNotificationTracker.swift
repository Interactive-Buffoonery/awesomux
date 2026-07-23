import AwesoMuxBridgeProtocol
import Foundation

public struct WorkspaceNotificationTracker: Sendable {
    // Baselines are tracked PER PANE (INT-504 R2): a session-level baseline is
    // lossy when one pane is acknowledged (−1) while a sibling goes unread (+1)
    // — the session total is unchanged and the sibling's attention is missed.
    // The session sum is for badge DISPLAY only, never the fire/no-fire decision.
    private var unreadCountsByPaneID: [TerminalPane.ID: Int]
    private let policy: WorkspaceNotificationPolicy

    public init(
        groups: [SessionGroup] = [],
        policy: WorkspaceNotificationPolicy = WorkspaceNotificationPolicy()
    ) {
        unreadCountsByPaneID = Self.unreadCountsByPaneID(in: groups)
        self.policy = policy
    }

    public mutating func reset(groups: [SessionGroup]) {
        unreadCountsByPaneID = Self.unreadCountsByPaneID(in: groups)
    }

    public mutating func notificationEvents(
        afterUpdating groups: [SessionGroup],
        selectedSessionID: TerminalSession.ID?,
        isAppActive: Bool = true,
        outputMarksNeedsAttention: Bool = true,
        notifyOnNeedsAttention: Bool = true,
        notifyOnTurnDone: Bool = false,
        turnDoneAlertsWhenFocused: Bool = false
    ) -> [WorkspaceNotificationEvent] {
        // One banner per workspace (notification routing redesign is out of scope
        // — INT-504 "What we are not doing"). We collect the first pane in each
        // session that crosses its own baseline, then emit one event per session.
        var firingSessionIDs = Set<TerminalSession.ID>()
        var pendingEmissions: [(session: TerminalSession, groupName: String, kind: WorkspaceNotificationEvent.Kind)] = []
        var seenPaneIDs = Set<TerminalPane.ID>()

        for group in groups {
            for session in group.sessions {
                let focusContext = policy.focusContext(
                    isSelectedWorkspace: session.id == selectedSessionID,
                    isAppActive: isAppActive
                )

                for pane in session.panes {
                    seenPaneIDs.insert(pane.id)

                    let previousCount = unreadCountsByPaneID[pane.id] ?? 0
                    let currentCount = pane.unreadNotificationCount

                    // Muted workspaces swallow banners rather than defer them:
                    // advance the baseline so unmuting later doesn't burst-fire
                    // banners for attention that arrived while muted (INT-598).
                    // The sidebar rollup still shows the unread state, so
                    // nothing is silently lost — it's just not interruptive.
                    if session.notificationsMuted {
                        unreadCountsByPaneID[pane.id] = currentCount
                        continue
                    }

                    let channels = policy.channels(
                        executionState: pane.agentExecutionState,
                        attentionReason: pane.attentionReason,
                        focusContext: focusContext,
                        outputMarksNeedsAttention: outputMarksNeedsAttention,
                        isWorkspaceMuted: session.notificationsMuted
                    )

                    // Turn-end (.waiting, no blocking prompt) is opt-in and,
                    // unless the focused sub-option is on, fires only for a
                    // workspace you are not currently looking at — the in-app
                    // chrome already carries a focused turn-end.
                    let turnDoneFocusOK = focusContext != .selectedWorkspaceActive
                        || turnDoneAlertsWhenFocused
                    let waitingTurnCompletionCanNotify = notifyOnTurnDone
                        && pane.agentExecutionState == .waiting
                        && pane.attentionReason == nil
                        && outputMarksNeedsAttention
                        && turnDoneFocusOK

                    if channels.isEmpty && !waitingTurnCompletionCanNotify {
                        // Pane is no longer notification-eligible (e.g. acked into
                        // .running). Reset its baseline so a later attention
                        // episode starts from zero.
                        unreadCountsByPaneID[pane.id] = currentCount
                        continue
                    }

                    // Gate the needs-attention channel on its own toggle so the
                    // tracker's fire/kind decision matches what the bridge will
                    // actually deliver. A needs-attention pane the user has
                    // toggled off must not (a) claim the workspace banner as
                    // `.needsAttention` only for `shouldDeliver` to drop it, nor
                    // (b) advance its baseline and starve a deliverable turn-done
                    // sibling. `channels.contains(.macOSNotification)` alone knows
                    // `attentionReason != nil`, not the toggle.
                    let needsAttentionCanNotify = channels.contains(.macOSNotification)
                        && notifyOnNeedsAttention
                    if (needsAttentionCanNotify || waitingTurnCompletionCanNotify),
                       currentCount > previousCount {
                        // One banner per workspace (routing redesign is out of
                        // scope): the workspace banner that fires this pass covers
                        // EVERY pane that crossed its baseline, so advance each
                        // crossing pane's baseline — not just the winner's — to
                        // avoid a second banner for the same workspace next pass.
                        // The sidebar rollup keeps a still-unread sibling loud, so
                        // nothing is silently lost.
                        unreadCountsByPaneID[pane.id] = currentCount
                        if firingSessionIDs.insert(session.id).inserted {
                            // Needs-attention is louder: if a real attention
                            // channel fired, label the workspace banner as such
                            // even when a sibling turn-end also crossed.
                            let kind: WorkspaceNotificationEvent.Kind =
                                needsAttentionCanNotify ? .needsAttention : .turnDone
                            pendingEmissions.append((session, group.name, kind))
                        } else if needsAttentionCanNotify,
                                  let index = pendingEmissions.firstIndex(where: {
                                      $0.session.id == session.id
                                  }) {
                            // A louder sibling crossed after the first pane already
                            // seeded a quieter turn-done kind for this workspace.
                            // Upgrade so "needs-attention wins" holds regardless of
                            // pane tree order — not just when the attention pane is
                            // reached first.
                            pendingEmissions[index].kind = .needsAttention
                        }
                    } else {
                        // Hold the baseline so a deferred banner re-surfaces on a
                        // later focus-loss re-evaluation.
                        unreadCountsByPaneID[pane.id] = previousCount
                    }
                }
            }
        }

        for paneID in Array(unreadCountsByPaneID.keys) where !seenPaneIDs.contains(paneID) {
            unreadCountsByPaneID.removeValue(forKey: paneID)
        }

        guard !pendingEmissions.isEmpty else {
            return []
        }

        // Disambiguation needs the full session set to detect collisions, so the
        // map is built across all groups — but only now that a banner is firing.
        let displayContextBySessionID = WorkspaceNotificationEvent.displayContextsBySessionID(in: groups)

        return pendingEmissions.map { emission in
            WorkspaceNotificationEvent(
                sessionID: emission.session.id,
                title: emission.session.title,
                groupName: emission.groupName,
                workingDirectory: emission.session.workingDirectory,
                displayContext: displayContextBySessionID[emission.session.id],
                // The loudest pane's kind, so the one-per-workspace banner icon
                // matches the sidebar rollup badge rather than whichever pane
                // happened to cross its baseline first in tree order (S2 /
                // INT-504 R2).
                agentKind: emission.session.agentRollup().winningAgentKind,
                unreadNotificationCount: emission.session.unreadNotificationCount,
                kind: emission.kind
            )
        }
    }

    private static func unreadCountsByPaneID(in groups: [SessionGroup]) -> [TerminalPane.ID: Int] {
        var unreadCountsByPaneID: [TerminalPane.ID: Int] = [:]
        for group in groups {
            for session in group.sessions {
                session.forEachPane { pane in
                    unreadCountsByPaneID[pane.id] = pane.unreadNotificationCount
                }
            }
        }
        return unreadCountsByPaneID
    }
}
