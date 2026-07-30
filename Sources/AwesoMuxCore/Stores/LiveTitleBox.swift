import Foundation
import Observation

/// Leading-edge "is a new publish due?" check, shared by the two live-title
/// paths that must not react to every OSC report: `LiveTitleBox`'s coarse
/// mirror and `SessionStore.bumpLiveTitleGenerationIfDue`.
///
/// Shared rather than copied because the whole subtlety is the negative case. A
/// negative elapsed means the wall clock went backwards (NTP step, manual clock
/// change, DST-adjacent shenanigans); treating that as "not due" would suppress
/// every publish until the clock caught back up — for a backwards jump of hours,
/// hours of a frozen sidebar. Two copies of a rule that non-obvious drift.
func liveTitleCoalescingWindowHasElapsed(
    since last: Date?,
    now: Date,
    interval: TimeInterval
) -> Bool {
    guard let last else { return true }
    let elapsed = now.timeIntervalSince(last)
    return elapsed < 0 || elapsed >= interval
}

/// Fine-grained notification channel for one workspace's chrome titles.
///
/// A display-only OSC title report writes `SessionStore` group storage
/// *silently* (see `SessionStore.withSilentGroupMutation`), so nothing that
/// observes `groups` is woken. Views that must visibly repaint on a spinner
/// frame observe this box instead: one box per session, because Observation
/// tracks per property and a single dictionary on the store would invalidate
/// every sidebar row (issue #311).
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
    /// How long the coarse mirror coalesces per-tick title writes.
    ///
    /// Measured, not guessed: with the fine channel already carrying the pane
    /// title bars, the residual per-animating-pane cost sat in the sidebar rows
    /// and the path bar, and 1 Hz is the point where that cost stops registering
    /// while the staleness stays invisible. A name in a sidebar row is not an
    /// animation — nobody perceives "cargo build" arriving a second late — which
    /// is exactly what makes this channel safe to slow down and the pane title
    /// bars' channel unsafe to touch.
    ///
    /// Deliberately its own constant rather than a share of
    /// `SessionStore.defaultLiveTitleGenerationInterval`, which currently holds
    /// the same value for a related-but-separate consumer (the sidebar's derived
    /// projections). They are tuned by different evidence and may diverge.
    nonisolated public static let coarseCoalescingInterval: TimeInterval = 1

    /// The workspace title `PaneLayoutReducer.syncSessionChromeToActivePane`
    /// promoted from the active pane.
    public private(set) var workspaceTitle: String = ""

    /// Displayed title per pane — the frozen custom title while
    /// `pane.isTitleUserEdited`, not the raw live terminal title, because that
    /// is what every render gate and label shows. Inactive panes stay in the
    /// map: a split session's panes have independent titles and
    /// `SidebarSessionTile` keys every one.
    public private(set) var paneTitles: [TerminalPane.ID: String] = [:]

    /// `workspaceTitle` and `paneTitles` again, published at most once per
    /// `coarseCoalescingInterval` on the per-tick path — what the consumers that
    /// render a NAME observe (`LiveTitleReads.everything`: the sidebar rows and
    /// the path bar).
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

    /// Nil until the first coalesced publish, which makes the very first title
    /// tick after a box is created a leading edge rather than a suppressed one.
    @ObservationIgnored private var lastCoarsePublish: Date?

    init() {}

    /// Mirrors `session`'s current chrome titles. Both writes are guarded:
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
    /// leaves `lastCoarsePublish` alone, so a rename never eats the next title
    /// tick's leading edge.
    func adopt(_ session: TerminalSession) {
        if workspaceTitle != session.title {
            workspaceTitle = session.title
        }
        var titles: [TerminalPane.ID: String] = [:]
        session.forEachPane { titles[$0.id] = $0.title }
        if paneTitles != titles {
            paneTitles = titles
        }
        publishCoarse()
    }

    /// Mirrors ONE pane's displayed title plus the workspace title its
    /// promotion may have moved.
    ///
    /// The hot path knows exactly which pane a report named, and `adopt`'s
    /// rebuild-and-full-compare is O(panes) per report — O(panes²) across a
    /// fully-animating split session, paid at the OSC throttle rate. Sibling
    /// panes cannot have moved: a display-only report touches one pane's
    /// chrome and, if that pane is active, the workspace title.
    ///
    /// `now` comes from the caller for the same reason
    /// `bumpLiveTitleGenerationIfDue` takes one: the OSC path already carries the
    /// write's timestamp, so the coalescing needs no clock of its own and tests
    /// need no sleep to cross the window.
    func adoptPaneTitle(
        _ paneID: TerminalPane.ID,
        title: String,
        workspaceTitle: String,
        now: Date
    ) {
        if self.workspaceTitle != workspaceTitle {
            self.workspaceTitle = workspaceTitle
        }
        if paneTitles[paneID] != title {
            paneTitles[paneID] = title
        }

        // Leading-edge on a timestamp taken at write time, deliberately not a
        // timer or a trailing debounce: coalescing that trails the last write
        // needs a scheduled wake-up, and the repo ratchets against new
        // sleeps/polling in production code (`script/check_test_waits.sh`).
        //
        // Ceiling, stated exactly: a title tick that lands inside the window,
        // with no later tick and no other publish, leaves the coarse mirror one
        // title behind — so a sidebar row can name a workspace by its
        // second-to-last title until something else publishes. Mitigation, and it
        // is a mitigation rather than a guarantee: an agent that stops reporting
        // titles is almost always an agent whose state changed, and attention /
        // unread / agent-state changes publish `groups`, which routes through
        // `adopt` and updates the mirror unthrottled.
        //
        // Upgrade path if a lagging row is ever actually observed: fold a
        // trailing flush into scheduling that already exists — the same
        // `onDisplayOnlyTitleWrite` hook `liveTitleGeneration` names — rather than
        // adding a timer here. Not done now because that hook is gated on the
        // `restoreWorkspaces` setting, and render correctness must not depend on
        // whether the user persists sessions.
        guard
            liveTitleCoalescingWindowHasElapsed(
                since: lastCoarsePublish,
                now: now,
                interval: Self.coarseCoalescingInterval
            )
        else { return }
        lastCoarsePublish = now
        publishCoarse()
    }

    /// Value-guarded like the fine writes above, so a tick that moved a title
    /// the coarse channel already carries publishes nothing.
    private func publishCoarse() {
        if coarseWorkspaceTitle != workspaceTitle {
            coarseWorkspaceTitle = workspaceTitle
        }
        if coarsePaneTitles != paneTitles {
            coarsePaneTitles = paneTitles
        }
    }
}
