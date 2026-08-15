import Foundation
import Observation

/// Leading-edge "is a new publish due?" check — the single live-title gate,
/// owned by `SessionStore.tickLiveTitle`, which both the coarse mirror's
/// per-tick publish and the `liveTitleGeneration` bump ride (issue #327).
///
/// Shared rather than copied because the whole subtlety is the negative case. A
/// negative elapsed means the wall clock went backwards (NTP step, manual clock
/// change, DST-adjacent shenanigans); treating that as "not due" would suppress
/// every publish until the clock caught back up — for a backwards jump of hours,
/// hours of a frozen sidebar.
///
/// Written as the negation of the ORIGINAL suppression predicate rather than as
/// the positive form it looks equivalent to. It is not equivalent: `interval`
/// reaches `SessionStore` from a public initializer and can be non-finite, and
/// every comparison against `NaN` is false. `elapsed < 0 ||
/// elapsed >= interval` would therefore return false for a `NaN` interval and
/// freeze the generation counter — and with it sidebar search, duplicate
/// ordinals, and the rotor — permanently after the first write, where the
/// original bumped every time. Keep this as a negation.
func liveTitleCoalescingWindowHasElapsed(
    since last: Date?,
    now: Date,
    interval: TimeInterval
) -> Bool {
    guard interval.isFinite else { return true }
    guard let last else { return true }
    let elapsed = now.timeIntervalSince(last)
    return !(elapsed >= 0 && elapsed < interval)
}

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
/// The box exposes the same titles on two channels — see `coarseWorkspaceTitle`
/// for why, and `LiveTitleReads` for which consumer reads which.
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

    /// `workspaceTitle` and `paneTitles` again, published on the per-tick path
    /// only when the session's coalescing window fires — what the consumers
    /// that render a NAME observe (`LiveTitleReads.everything`: the sidebar
    /// rows). The gate lives store-side in `SessionStore.tickLiveTitle`, not
    /// here: the same timestamp check that releases this publish also bumps
    /// `liveTitleGeneration`, so a sidebar row and every projection derived
    /// from it move on the same tick and can never name the workspace by
    /// different titles (issue #327).
    ///
    /// A profile under three animating panes put `SidebarSessionTile` at ~2.5x
    /// the next app frame, and almost none of it was the `Text`: it was SwiftUI
    /// *layout* — `sizeThatFits`, `placeChildren`, `explicitAlignment`, padding —
    /// plus the ARC and generic-metadata churn that rides along. Isolating the
    /// title into its own nested scope was built and measured and recovered
    /// nothing, because layout invalidation propagates upward from the changed
    /// leaf no matter which body re-ran. So the publish RATE is the only lever
    /// that moves, and it can only be pulled where staleness is imperceptible.
    ///
    /// Pane title bars deliberately keep reading the fine-grained properties
    /// above. An agent spinner's braille frame IS an animation, and coalescing it
    /// to 1 Hz reads as a stutter.
    public private(set) var coarseWorkspaceTitle: String = ""
    /// See `coarseWorkspaceTitle`.
    public private(set) var coarsePaneTitles: [TerminalPane.ID: String] = [:]

    init() {}

    /// Mirrors `session`'s current chrome titles. Writes are guarded:
    /// `@Observable` publishes on every set, and a title report against a
    /// user-edited pane moves only the live title, which is not displayed.
    ///
    /// Walks every pane, so it is the entry point for writes where the changed
    /// pane is unknown — a rename, a reset, a structural mutation, a bulk
    /// restore. The per-tick OSC path uses `adoptPaneTitle` instead.
    ///
    /// Publishes the coarse mirror **unthrottled**, and that split is the point
    /// of having two entry points. This one rides `_groups`' own `set`/`_modify`
    /// accessors (see `SessionStore.refreshLiveTitleBoxes`), so every non-tick
    /// writer reaches it by construction. Holding a rename back for the
    /// coalescing window would leave it invisible in the sidebar for up to a
    /// second — or indefinitely, if no title tick ever followed to flush it,
    /// because the box SHADOWS storage: a coarse publish that never happens shows
    /// a superseded title until something unrelated publishes, not for one frame.
    ///
    /// Takes no clock on purpose. It is reached from a storage accessor that has
    /// no `now` to hand it, and an unthrottled publish does not need one. It also
    /// never touches the store's coalescing stamps, so a rename neither eats the
    /// next title tick's leading edge nor earns a free one of its own.
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
        publishCoarse()
    }

    /// Mirrors ONE pane's displayed title plus the workspace title its
    /// promotion may have moved.
    ///
    /// The hot path knows exactly which pane a report named, so the fine-channel
    /// update is O(1). Sibling panes cannot have moved: a display-only report
    /// touches one pane's chrome and, if that pane is active, the workspace
    /// title. The coarse snapshot remains O(panes), but runs only when
    /// `publishCoarseNow` — the caller's per-session gate
    /// (`SessionStore.tickLiveTitle`) — fired.
    func adoptPaneTitle(
        _ paneID: TerminalPane.ID,
        title: String,
        workspaceTitle: String,
        publishCoarseNow: Bool
    ) {
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

        // The publish trigger is the caller's leading-edge gate, stamped at
        // write time — deliberately not a timer or a trailing debounce held by
        // the box: coalescing that trails the last write needs a scheduled
        // wake-up, and the repo ratchets against new sleeps/polling in
        // production code (`script/check_test_waits.sh`). Keeping ONE gate in
        // the store is also what makes the row and the title-derived
        // projections provably in phase; a second per-box window (its old
        // home) let them phase independently (issue #327).
        //
        // Ceiling, stated exactly: a title tick that lands inside the window,
        // with no later tick and no other publish, leaves the coarse mirror one
        // title behind — so a sidebar row can name a workspace by its
        // second-to-last title until something else publishes. Every surface
        // derived from the mirror lags TOGETHER with it; what it cannot do any
        // more is disagree with the row.
        //
        // Partial mitigation, and the limits of it matter as much as the
        // mitigation: attention / unread / agent-state changes publish `groups`,
        // which routes through `adopt` and updates the mirror unthrottled, so an
        // AGENT pane that goes quiet is usually corrected. That does NOT cover a
        // plain foreground process with no agent state — a `vite` / `cargo
        // watch` / `pytest -f` watcher that titles itself twice per rebuild and
        // then sits idle publishes no `groups` at all (`updateShellActivity`
        // fires only on an activity CHANGE, and the shell stays busy). For that
        // pane the mirror can name the previous rebuild's outcome for as long as
        // the user leaves it alone. That is a real, ordinary case, not a
        // theoretical one; it is accepted here rather than hidden.
        //
        // Upgrade path if it is ever actually reported: fold a trailing flush
        // into scheduling that already exists — the same `onDisplayOnlyTitleWrite`
        // hook `liveTitleGeneration` names — rather than adding a timer here. Not
        // done now because that hook is gated on the `restoreWorkspaces` setting,
        // and render correctness must not depend on whether the user persists
        // sessions.
        //
        // Any consumer that uses these titles as an edge-triggered SIGNAL rather
        // than as text must stay on the fine channel — a coalesced channel drops
        // intermediate values, and a dropped edge is not a late edge. See
        // `LiveTitleReads.workspaceAndPaneTitle`.
        if publishCoarseNow {
            publishCoarse()
        }
    }

    /// Value-guarded like the fine writes above, so a tick that moved a title
    /// the coarse channel already carries publishes nothing.
    private func publishCoarse() {
        if coarseWorkspaceTitle != workspaceTitle {
            coarseWorkspaceTitle = workspaceTitle
        }
        let finePaneTitles = paneTitles
        if coarsePaneTitles != finePaneTitles {
            coarsePaneTitles = finePaneTitles
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
