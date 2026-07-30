import Foundation
import Observation

/// Fine-grained notification channel for one workspace's chrome titles.
///
/// A display-only OSC title report writes `SessionStore` group storage
/// *silently* (see `SessionStore.withSilentGroupMutation`), so nothing that
/// observes `groups` is woken. Views that must visibly repaint on a spinner
/// frame observe this box instead: one box per session, because Observation
/// tracks per property and a single dictionary on the store would invalidate
/// every sidebar row (issue #311).
///
/// The box is a notification channel, not a second source of truth — its values
/// always mirror what was just written to storage, so `snapshot()` needs no
/// fold and any reader that prefers the struct stays correct.
@MainActor
@Observable
public final class LiveTitleBox {
    /// The workspace title `PaneLayoutReducer.syncSessionChromeToActivePane`
    /// promoted from the active pane.
    public private(set) var workspaceTitle: String = ""

    /// Displayed title per pane — the frozen custom title while
    /// `pane.isTitleUserEdited`, not the raw live terminal title, because that
    /// is what every render gate and label shows. Inactive panes stay in the
    /// map: a split session's panes have independent titles and
    /// `SidebarSessionTile` keys every one.
    public private(set) var paneTitles: [TerminalPane.ID: String] = [:]

    init() {}

    /// Mirrors `session`'s current chrome titles. Both writes are guarded:
    /// `@Observable` publishes on every set, and a title report against a
    /// user-edited pane moves only the live title, which is not displayed.
    ///
    /// Walks every pane, so it is the entry point for writes where the changed
    /// pane is unknown — a rename, a reset, a structural mutation, a bulk
    /// restore. The per-tick OSC path uses `adoptPaneTitle` instead.
    func adopt(_ session: TerminalSession) {
        if workspaceTitle != session.title {
            workspaceTitle = session.title
        }
        var titles: [TerminalPane.ID: String] = [:]
        session.forEachPane { titles[$0.id] = $0.title }
        if paneTitles != titles {
            paneTitles = titles
        }
    }

    /// Mirrors ONE pane's displayed title plus the workspace title its
    /// promotion may have moved.
    ///
    /// The hot path knows exactly which pane a report named, and `adopt`'s
    /// rebuild-and-full-compare is O(panes) per report — O(panes²) across a
    /// fully-animating split session, paid at the OSC throttle rate. Sibling
    /// panes cannot have moved: a display-only report touches one pane's
    /// chrome and, if that pane is active, the workspace title.
    func adoptPaneTitle(_ paneID: TerminalPane.ID, title: String, workspaceTitle: String) {
        if self.workspaceTitle != workspaceTitle {
            self.workspaceTitle = workspaceTitle
        }
        if paneTitles[paneID] != title {
            paneTitles[paneID] = title
        }
    }
}
