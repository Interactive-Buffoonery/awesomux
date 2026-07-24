import Foundation

/// Decision logic for healing wedged sheet-request state (issue #202).
///
/// `isAnySheetPresented` derives from request *intent* (the seven sheet-request
/// vars plus the scrollback-dump flag), not presentation *truth*. A request
/// whose sheet never mounts wedges non-nil forever — its dismiss handlers live
/// inside sheet content that never appeared — which invisibly disables ⌘F, ⌘W,
/// and the workspace command surface app-wide. This policy decides, from two
/// snapshots taken across a stabilization beat on app/window activation,
/// which pending keys are genuinely wedged and safe to clear.
///
/// Extracted as a pure function (precedent: `WorkspaceCommandShortcutPolicy`)
/// so the heal/no-heal decision is unit-testable without AppKit.
enum SheetWedgeRecoveryPolicy {
    /// A stable name for the scrollback-dump flag operand, which is keyed by
    /// pane rather than being one of the seven request vars.
    static let scrollbackDumpKey = "scrollbackDump"

    struct Snapshot: Equatable {
        /// Stable key per non-nil sheet-request var (e.g. "workspaceEdit").
        var pendingRequestKeys: Set<String>

        /// Panes with the scrollback-dump sheet flag raised.
        var scrollbackDumpPaneCount: Int

        /// AppKit presentation truth: `NSApp.modalWindow != nil` (run-modal
        /// alerts attach no sheet) or any window with an `attachedSheet`.
        var hasNativeModalPresentation: Bool
    }

    /// Keys that are wedged and safe to clear. A key heals only when it was
    /// pending in BOTH snapshots (the stabilization epoch — a request set just
    /// before activation gets one beat to mount its sheet) and nothing is
    /// natively presented at recheck time.
    ///
    /// ponytail: a same-kind request replaced within the beat is healed with
    /// its predecessor — the replacement also failed to present within the
    /// grace window, and cancelling a delayed presentation is the accepted
    /// cost of never leaving the app permanently wedged.
    static func keysToHeal(initial: Snapshot, recheck: Snapshot) -> Set<String> {
        guard !recheck.hasNativeModalPresentation else { return [] }
        var keys = initial.pendingRequestKeys.intersection(recheck.pendingRequestKeys)
        if initial.scrollbackDumpPaneCount > 0, recheck.scrollbackDumpPaneCount > 0 {
            keys.insert(scrollbackDumpKey)
        }
        return keys
    }
}
