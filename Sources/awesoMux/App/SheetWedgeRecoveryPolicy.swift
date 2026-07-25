import AwesoMuxCore
import Foundation

/// Decision logic for healing wedged sheet-request state (issue #202).
///
/// `isAnySheetPresented` derives from request *intent* (the seven sheet-request
/// vars plus the scrollback-dump flag), not presentation *truth*. A request
/// whose sheet never mounts wedges non-nil forever — its dismiss handlers live
/// inside sheet content that never appeared — which invisibly disables ⌘F, ⌘W,
/// and the workspace command surface app-wide. This policy decides, from
/// snapshots of request intent versus AppKit presentation truth, which pending
/// keys are genuinely wedged and safe to clear.
///
/// Veto scoping is per operand class: the seven request sheets present on the
/// primary content window, so only a primary-window sheet vetoes their heal;
/// scrollback dumps can be hosted in floating/companion panels, so any
/// window's sheet vetoes theirs. A run-modal window vetoes everything.
///
/// SAFETY INVARIANT: consent, trust, or destructive-confirmation sheets must
/// never be modeled as healable request vars — every key here must be safe to
/// silently discard. (Verified at introduction: none of the seven is a trust
/// gate; SSH host-key trust lives in the spawned ssh child.)
///
/// Extracted as pure functions (precedent: `WorkspaceCommandShortcutPolicy`)
/// so heal/no-heal decisions are unit-testable without AppKit.
enum SheetWedgeRecoveryPolicy {
    /// Stable name for the scrollback-dump operand, keyed by pane rather than
    /// being one of the seven request vars.
    static let scrollbackDumpKey = "scrollbackDump"

    struct Snapshot: Equatable {
        /// Stable key per non-nil sheet-request var (e.g. "workspaceEdit").
        var pendingRequestKeys: Set<String>

        /// Panes with the scrollback-dump sheet flag raised.
        var scrollbackDumpPaneIDs: Set<TerminalPane.ID>

        /// `NSApp.modalWindow != nil` — run-modal alerts attach no sheet.
        var hasModalWindow: Bool

        /// The primary content window has an `attachedSheet`.
        var primaryWindowSheetAttached: Bool

        /// Any window app-wide has an `attachedSheet`.
        var anyWindowSheetAttached: Bool
    }

    /// Pure mapping from the seven request vars to their stable keys, so the
    /// snapshot construction is testable without a hosting harness.
    static func pendingRequestKeys(
        workspaceEdit: Bool,
        paneEdit: Bool,
        workspaceGroupCreate: Bool,
        remoteWorkspaceGroupCreate: Bool,
        sshWorkspaceConnect: Bool,
        workspaceGroupRename: Bool,
        quickSettings: Bool
    ) -> Set<String> {
        var keys: Set<String> = []
        if workspaceEdit { keys.insert("workspaceEdit") }
        if paneEdit { keys.insert("paneEdit") }
        if workspaceGroupCreate { keys.insert("workspaceGroupCreate") }
        if remoteWorkspaceGroupCreate { keys.insert("remoteWorkspaceGroupCreate") }
        if sshWorkspaceConnect { keys.insert("sshWorkspaceConnect") }
        if workspaceGroupRename { keys.insert("workspaceGroupRename") }
        if quickSettings { keys.insert("quickSettings") }
        return keys
    }

    /// Keys that are wedged and safe to clear. A key heals only when it was
    /// pending in BOTH snapshots (the stabilization epoch — a request set just
    /// before the trigger gets one beat to mount its sheet; synchronous
    /// callers pass the same snapshot twice, trading that grace for the
    /// certainty of a live keypress) and its operand class has no vetoing
    /// presentation at recheck time.
    ///
    /// ponytail: a same-kind request replaced within the beat is healed with
    /// its predecessor — the replacement also failed to present within the
    /// grace window, and cancelling a delayed presentation is the accepted
    /// cost of never leaving the app permanently wedged.
    static func keysToHeal(initial: Snapshot, recheck: Snapshot) -> Set<String> {
        guard !recheck.hasModalWindow else { return [] }
        var keys: Set<String> = []
        if !recheck.primaryWindowSheetAttached {
            keys = initial.pendingRequestKeys.intersection(recheck.pendingRequestKeys)
        }
        if !scrollbackPaneIDsToHeal(initial: initial, recheck: recheck).isEmpty {
            keys.insert(scrollbackDumpKey)
        }
        return keys
    }

    /// Scrollback-dump flags heal per pane identity, never by count — a wedged
    /// pane clearing while another raises a fresh, legitimately-unmounted dump
    /// must not get the fresh one force-dismissed.
    static func scrollbackPaneIDsToHeal(
        initial: Snapshot,
        recheck: Snapshot
    ) -> Set<TerminalPane.ID> {
        guard !recheck.hasModalWindow, !recheck.anyWindowSheetAttached else { return [] }
        return initial.scrollbackDumpPaneIDs.intersection(recheck.scrollbackDumpPaneIDs)
    }
}
