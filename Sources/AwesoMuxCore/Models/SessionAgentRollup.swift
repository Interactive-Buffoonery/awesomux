import AwesoMuxBridgeProtocol
import Foundation

/// A single pane's agent signal, the input to a session-level rollup. Post
/// INT-504 each `TerminalPane` projects one of these; the rollup folds them
/// into the session's displayed state without losing which pane owns it.
public struct PaneAgentSnapshot: Equatable, Sendable {
    public let paneID: UUID
    public let agentKind: AgentKind
    public let state: AgentDisplayState
    public let unread: Int
    public let isQuitRisk: Bool
    /// Raw `attentionReason != nil` for the pane — the acknowledgement signal.
    /// Carried separately from `state` so the rollup's `attentionPaneIDs` derives
    /// from the SAME condition as `TerminalSession.needsAcknowledgement` instead
    /// of inferring it from the chrome-collapsed `state == .needsAttention`,
    /// which only agrees by accident (C1 / INT-504 review).
    public let needsAcknowledgement: Bool
    /// The pane's raw attention reason, carried alongside `needsAcknowledgement`
    /// so a session-level consumer (the workspace VoiceOver tracker) can tell
    /// a `.processError` crossing apart from other `needsAttention` causes —
    /// `.processError` already gets a specific "pane exited with error"
    /// announcement from the view layer at the moment it's recorded, so the
    /// generic rollup-level announcement must not repeat it (INT-642).
    public let attentionReason: AttentionReason?

    public init(
        paneID: UUID,
        agentKind: AgentKind,
        state: AgentDisplayState,
        unread: Int,
        isQuitRisk: Bool,
        needsAcknowledgement: Bool,
        attentionReason: AttentionReason? = nil
    ) {
        self.paneID = paneID
        self.agentKind = agentKind
        self.state = state
        self.unread = unread
        self.isQuitRisk = isQuitRisk
        self.needsAcknowledgement = needsAcknowledgement
        self.attentionReason = attentionReason
    }
}

/// The session-level projection of its panes' agent state. Carries pane
/// *ownership* (not just a bare display state) so the sidebar glyph, peek card,
/// notification text, and VoiceOver label can all point at the pane that earned
/// the state — the review's load-bearing correction (INT-504 R1).
public struct SessionAgentRollup: Equatable, Sendable {
    /// The loudest pane's display state — what the sidebar tile shows.
    public let state: AgentDisplayState
    /// The pane that owns `state`. The icon follows this pane, so a Codex pane
    /// needing attention never renders under a sibling shell's identity.
    public let winningPaneID: UUID
    public let winningAgentKind: AgentKind
    /// Summed across panes — for badge display only. The fire/no-fire
    /// notification decision uses per-pane baselines, never this sum.
    public let unreadTotal: Int

    /// The panes this rollup was folded from. Retained so the pane-ID
    /// projections below stay LAZY: the hot render path reads only
    /// `state`/`winningPaneID`/`winningAgentKind`/`unreadTotal`, so the two
    /// filters are deferred to the rare caller that actually needs them.
    private let snapshots: [PaneAgentSnapshot]

    /// Panes whose `attentionReason != nil` — the exact acknowledgement set,
    /// derived from the per-pane signal so it cannot drift from
    /// `TerminalSession.needsAcknowledgement` (C1).
    public var attentionPaneIDs: [UUID] {
        snapshots.filter(\.needsAcknowledgement).map(\.paneID)
    }

    public var quitRiskPaneIDs: [UUID] {
        snapshots.filter(\.isQuitRisk).map(\.paneID)
    }

    /// Attention reasons of every acknowledgement-needing pane (INT-642 dedup
    /// input). Per-pane, not just the winner's: every reason collapses to the
    /// same `.needsAttention` priority tier, so ties resolve by traversal
    /// order — a `.processError` winner can sit next to a `.permissionPrompt`
    /// sibling whose attention was never announced anywhere else.
    public var attentionReasons: [AttentionReason] {
        snapshots.filter(\.needsAcknowledgement).compactMap(\.attentionReason)
    }

    public init(
        state: AgentDisplayState,
        winningPaneID: UUID,
        winningAgentKind: AgentKind,
        unreadTotal: Int,
        snapshots: [PaneAgentSnapshot] = []
    ) {
        self.state = state
        self.winningPaneID = winningPaneID
        self.winningAgentKind = winningAgentKind
        self.unreadTotal = unreadTotal
        self.snapshots = snapshots
    }

    /// Folds per-pane snapshots into one rollup. The winner is the pane with
    /// the most urgent `AgentDisplayState.priority` (lower wins); ties resolve
    /// to the first pane in input order, so a stable pane traversal yields a
    /// stable badge. Returns nil only for empty input — a real session always
    /// has at least one pane.
    public static func from(_ snapshots: [PaneAgentSnapshot]) -> SessionAgentRollup? {
        // `min(by:)` with a strict comparator keeps the first of equal minima,
        // which is the stable-tie behavior the contract requires.
        guard let winner = snapshots.min(by: { $0.state.priority < $1.state.priority }) else {
            return nil
        }
        return SessionAgentRollup(
            state: winner.state,
            winningPaneID: winner.paneID,
            winningAgentKind: winner.agentKind,
            unreadTotal: snapshots.reduce(0) { $0 + $1.unread },
            snapshots: snapshots
        )
    }
}
