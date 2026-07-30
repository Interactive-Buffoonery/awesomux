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
    /// moves when the pane roster does — normally a structural mutation that
    /// publishes `groups` anyway, so it costs nothing per tick. (The one
    /// exception is `adoptPaneTitle` seeding a pane's first channel on the
    /// silent path; see there. It is bounded at one wake per pane.)
    ///
    /// Keeping it observable closes the two ways per-pane storage could
    /// otherwise freeze a title bar permanently: a reader that resolved no
    /// channel would hold no dependency at all and could never learn that one
    /// appeared, and a replaced channel would orphan every reader already
    /// registered on the old one. Under `@ObservationIgnored` both are
    /// permanent, because a channel is preferred over the session struct
    /// wherever one exists.
    ///
    /// Both read paths below touch this property before resolving a channel, so
    /// no reader can hold a channel dependency without also holding the roster
    /// dependency. That is what makes the two freezes above unreachable, and it
    /// is a feature rather than an imprecision in those two doc comments.
    private var paneChannels: [TerminalPane.ID: LivePaneTitle] = [:]

    /// Displayed title per pane — the frozen custom title while
    /// `pane.isTitleUserEdited`, not the raw live terminal title, because that
    /// is what every render gate and label shows. Inactive panes stay in the
    /// map: a split session's panes have independent titles and
    /// `SidebarSessionTile` keys every one.
    ///
    /// Reading this registers a dependency on EVERY pane, which is what a
    /// consumer that renders every pane wants and what a single title bar must
    /// avoid — that one uses `paneTitle(for:)`.
    ///
    /// Ceiling, accepted deliberately: computing this allocates a fresh P-entry
    /// dictionary per read, and the resulting `LiveTitles` comparison loses
    /// `Dictionary.==`'s identical-storage fast path, so an unchanged compare
    /// walks the keys instead of comparing one pointer. Immaterial at the P a
    /// real split reaches, and the alternative — keeping a stored mirror —
    /// would be a second shadowing surface with its own refresh obligation,
    /// which is the bug class this whole subsystem exists to avoid. If a
    /// many-pane split ever measures worse, narrow the `.everything` call sites
    /// rather than caching.
    public var paneTitles: [TerminalPane.ID: String] {
        paneChannels.mapValues(\.title)
    }

    /// One pane's displayed title, registering a dependency on that pane's own
    /// channel plus the roster (see `paneChannels`) — and on no sibling pane,
    /// which is the point.
    public func paneTitle(for paneID: TerminalPane.ID) -> String? {
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
            // Load-bearing, NOT dead — do not delete it as unreachable.
            // `SessionStore.liveTitleBox(for:)` caches a new box
            // unconditionally but only adopts when
            // `storedSessionForLiveTitleBox` finds the session, which it
            // deliberately does not mid-structural-mutation. That box has no
            // channels, and the next silent report lands right here. Dropping
            // the title instead would freeze that pane's bar until the next
            // publish; seeding costs one session-wide wake, once per pane.
            paneChannels[paneID] = LivePaneTitle(title: title)
        }
    }
}

/// One pane's displayed title, as its own observable so that writing it wakes
/// only the views rendering that pane.
///
/// File-private, and `LiveTitleBox.paneChannels` is private, so a reference
/// cannot escape the box. `adopt` reuses a live pane's channel, but a channel is
/// dropped when its pane closes and a pane that returns gets a fresh one — so a
/// captured reference can outlive the channel the box actually writes to, and
/// whatever registered on it would freeze. That is the one obligation this
/// design could have left to a future caller to remember, and the visibility
/// removes it rather than documenting it.
@MainActor
@Observable
private final class LivePaneTitle {
    var title: String

    init(title: String) {
        self.title = title
    }
}
