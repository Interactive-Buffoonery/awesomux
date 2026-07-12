import Foundation

/// Describes derived-state repair required after a store mutation.
///
/// Public `SessionStore` methods produce this; only `commit(_:now:)` consumes it.
/// Tree writes to `_groups` stay adjacent to effect construction — this value
/// owns **cache** repair (index, unread, risk, remote membership, selection
/// after rebuild), not the workspace tree itself (F30).
struct WorkspaceMutationEffect: Equatable, Sendable {
    /// When true, rebuild index + unread total + risk sets + remote panes +
    /// prune reducers + prune pins. Patch fields below are ignored.
    var needsFullRebuild: Bool = false

    /// Patch unread total (ignored when `needsFullRebuild` is true).
    var unreadChange: WorkspaceAttentionReducer.UnreadChange? = nil

    /// Sessions whose quit-risk membership must be reclassified (ignored when
    /// full rebuild).
    var riskSessionIDs: Set<TerminalSession.ID> = []

    /// Remote pane membership patches (ignored when full rebuild rebuilds
    /// `remotePaneIDs` from the tree). Key = pane ID, value = true insert /
    /// false remove — match `updatePane` semantics exactly.
    var remotePaneMembership: [TerminalPane.ID: Bool] = [:]

    /// Selection applied **after** tree/cache repair. Always an unconditional
    /// write when `.set` (INT-652): same-value re-assign must still publish.
    var selection: SelectionAfterRepair = .unchanged

    enum SelectionAfterRepair: Equatable, Sendable {
        case unchanged
        case set(TerminalSession.ID?)
    }
}
