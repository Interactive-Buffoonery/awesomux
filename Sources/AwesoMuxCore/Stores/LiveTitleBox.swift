import Foundation
import Observation

/// Fine-grained notification channel for one workspace's chrome titles.
///
/// A display-only OSC title report writes `SessionStore` group storage
/// *silently* (see `SessionStore.withSilentGroupMutation`), so nothing that
/// observes `groups` is woken. Views that must visibly repaint on a spinner
/// frame observe this box instead.
///
/// Observation tracks per PROPERTY, not per key, so the granularity of the
/// storage is the granularity of the invalidation. That is why this is two
/// levels deep: one box per session, because a single dictionary on the store
/// would invalidate every sidebar row (issue #311), and one `LivePaneTitle` per
/// pane, because a single dictionary on the box would invalidate every sibling
/// pane's title bar (issue #315).
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

    /// One channel per pane, so a pane's spinner frame wakes only the views
    /// that render THAT pane.
    ///
    /// Observable on purpose, rather than `@ObservationIgnored`. Membership
    /// moves only when the pane roster does, which is always a structural
    /// mutation that publishes `groups` anyway, so it costs nothing per tick —
    /// and it closes the two ways per-pane storage could otherwise freeze a
    /// title bar permanently: a reader that resolved no channel would hold no
    /// dependency at all and could never learn that one appeared, and a
    /// replaced channel would orphan every reader already registered on the old
    /// one. Under `@ObservationIgnored` both are permanent, because the channel
    /// is preferred over the session struct wherever one exists.
    private var paneChannels: [TerminalPane.ID: LivePaneTitle] = [:]

    /// Displayed title per pane — the frozen custom title while
    /// `pane.isTitleUserEdited`, not the raw live terminal title, because that
    /// is what every render gate and label shows. Inactive panes stay in the
    /// map: a split session's panes have independent titles and
    /// `SidebarSessionTile` keys every one.
    ///
    /// Reading this registers a dependency on EVERY pane, which is what a
    /// consumer that renders every pane wants and what a single title bar must
    /// avoid — that one uses `paneTitle(_:)`.
    public var paneTitles: [TerminalPane.ID: String] {
        paneChannels.mapValues(\.title)
    }

    /// One pane's displayed title, registering a dependency on that pane alone.
    public func paneTitle(_ paneID: TerminalPane.ID) -> String? {
        paneChannels[paneID]?.title
    }

    init() {}

    /// Mirrors `session`'s current chrome titles. Every write is guarded:
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
        var live: Set<TerminalPane.ID> = []
        session.forEachPane { pane in
            live.insert(pane.id)
            // Reuse, never replace. A fresh channel per refresh would publish
            // `paneChannels` on every publishing write and hand back the
            // sibling fan-out #315 removed — silently, with every correctness
            // test still green.
            if let channel = paneChannels[pane.id] {
                if channel.title != pane.title {
                    channel.title = pane.title
                }
            } else {
                paneChannels[pane.id] = LivePaneTitle(title: pane.title)
            }
        }
        // Superset comparison, and it depends on the loop above having inserted
        // every live pane FIRST: `paneChannels ⊇ live` at this point, so a count
        // mismatch is exactly "some channel outlived its pane". Reordering the
        // loop would leak one channel per closed pane for the box's lifetime.
        if live.count != paneChannels.count {
            paneChannels = paneChannels.filter { live.contains($0.key) }
        }
    }

    /// Mirrors ONE pane's displayed title plus the workspace title its
    /// promotion may have moved.
    ///
    /// The hot path knows exactly which pane a report named, and `adopt`'s
    /// walk-and-compare is O(panes) per report — O(panes²) across a fully
    /// animating split session, paid at the OSC throttle rate. Sibling panes
    /// cannot have moved: a display-only report touches one pane's chrome and,
    /// if that pane is active, the workspace title.
    func adoptPaneTitle(_ paneID: TerminalPane.ID, title: String, workspaceTitle: String) {
        if self.workspaceTitle != workspaceTitle {
            self.workspaceTitle = workspaceTitle
        }
        if let channel = paneChannels[paneID] {
            if channel.title != title {
                channel.title = title
            }
        } else {
            // No known path reaches here — `adopt` seeds a channel for every
            // pane before any report can name one. Kept because the fallback of
            // dropping the title would be a frozen title bar rather than a
            // one-frame lag, and seeding costs one session-wide wake once.
            paneChannels[paneID] = LivePaneTitle(title: title)
        }
    }
}

/// One pane's displayed title, as its own observable so that writing it wakes
/// only the views rendering that pane.
///
/// File-private, and `LiveTitleBox.paneChannels` is private, so a reference
/// cannot escape the box: `adopt` replaces channels when the roster changes, and
/// a captured stale channel would freeze whatever registered on it. That is the
/// one obligation this design could have left to a future caller to remember,
/// and the visibility removes it rather than documenting it.
@MainActor
@Observable
private final class LivePaneTitle {
    var title: String

    init(title: String) {
        self.title = title
    }
}
