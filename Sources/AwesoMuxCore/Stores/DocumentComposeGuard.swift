import Foundation

/// Lets the document view layer tell the store when a comment popover is open
/// over the selected document tab, so an agent-driven open can append its tab
/// WITHOUT selecting it — a selection swap remounts the document view and
/// destroys the popover's typed draft (INT-748).
///
/// A registered closure rather than a stored flag because the popover is
/// `.transient`: it closes on any outside click without notifying our code, so
/// only a live `isShown` read is trustworthy. User-initiated opens (menu,
/// panel, terminal link) involve a click that already closed the popover, so
/// in practice only the agent-hook path ever sees `true`.
@MainActor
public enum DocumentComposeGuard {
    /// Registered at app startup by the view layer. Defaults to "not composing"
    /// so headless/test stores never defer selection.
    public static var isComposing: () -> Bool = { false }
}
