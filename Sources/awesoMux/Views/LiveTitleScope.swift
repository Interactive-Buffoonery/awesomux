import AwesoMuxCore
import SwiftUI

/// A workspace's CURRENT chrome titles, snapshotted out of its `LiveTitleBox`
/// by `LiveTitleScope`.
///
/// A display-only OSC title report writes `SessionStore` group storage
/// *silently* (issue #311), so the `TerminalSession` value a view was handed
/// at its last render can name a title several seconds stale. These are the
/// displayed titles as of this render — or as of the last coarse publish, for
/// `reads: .everything`. The fallbacks keep call sites correct wherever no
/// channel is injected (tests, previews, detached roots), where the struct's
/// own title is by definition the freshest thing available.
struct LiveTitles: Equatable {
    /// No channel available — every lookup falls back to the struct.
    static let unavailable = LiveTitles(workspace: nil, panes: [:])

    let workspace: String?
    let panes: [TerminalPane.ID: String]

    init(workspace: String?, panes: [TerminalPane.ID: String]) {
        self.workspace = workspace
        self.panes = panes
    }

    /// Snapshots only what `reads` names, so a scope is not woken by a property
    /// it does not render — and picks which CHANNEL it reads. No default: see
    /// `LiveTitleReads`, where the choice between the fine and coarse channels is
    /// a correctness decision, not a tuning one.
    @MainActor
    init(box: LiveTitleBox?, reads: LiveTitleReads) {
        switch reads {
        case .workspaceTitle:
            workspace = box?.workspaceTitle
            panes = [:]
        case let .paneTitle(paneID):
            workspace = nil
            // `paneTitle(for:)`, never `paneTitles[paneID]`: the box stores one
            // observable per pane, so this depends on that pane's channel and
            // the pane roster, and on no sibling pane (issue #315). Reading the
            // dictionary would register every pane and put the sibling fan-out
            // straight back — a sibling's spinner frame would re-run this scope,
            // and only the child `.equatable()` gate downstream would reject the
            // work, after the scope evaluation and comparison had been paid.
            panes = box?.paneTitle(for: paneID).map { [paneID: $0] } ?? [:]
        case let .workspaceAndPaneTitle(paneID):
            // FINE for both, deliberately. See the case's own doc comment: this
            // exists because the path bar's titles are an edge-triggered signal,
            // and the coarse channel drops intermediate values rather than
            // delaying them.
            workspace = box?.workspaceTitle
            panes = box?.paneTitle(for: paneID).map { [paneID: $0] } ?? [:]
        case .everything:
            // The COARSE mirror, not the fine properties the other two cases
            // read. `.everything` is exactly the consumers that render a NAME —
            // sidebar rows — where a second of staleness is not
            // observable but the per-tick re-layout is the measured residual
            // cost. See `LiveTitleBox.coarseWorkspaceTitle`.
            workspace = box?.coarseWorkspaceTitle
            panes = box?.coarsePaneTitles ?? [:]
        }
    }

    func workspaceTitle(for session: TerminalSession) -> String {
        workspace ?? session.title
    }

    func paneTitle(for pane: TerminalPane) -> String {
        panes[pane.id] ?? pane.title
    }
}

/// Which of `LiveTitleBox`'s observable properties a scope reads.
///
/// `@Observable` invalidates per property, so this is a real observation
/// boundary and not bookkeeping: the app titlebar renders only the workspace
/// title, and declaring that keeps an INACTIVE pane's spinner from waking it at
/// all. `.paneTitle` narrows further, to the one pane's own channel. Pick the
/// narrowest case the content can render from.
///
/// It also picks the CHANNEL. The first three cases read the fine-grained
/// properties and repaint on every relevant title report; `.everything` reads
/// the ~1 Hz coarse mirror. That is a product decision as much as a performance
/// one — an agent spinner in a pane title bar has to animate, a workspace name
/// in a sidebar row does not.
enum LiveTitleReads: Equatable {
    /// `workspaceTitle` only — the app titlebar. Fine-grained.
    case workspaceTitle
    /// One pane's title only — a pane title bar. Fine-grained, so a spinner
    /// stays smooth.
    case paneTitle(TerminalPane.ID)
    /// The workspace title plus ONE pane's title, both fine-grained — the path
    /// bar.
    ///
    /// Reads the same two values `.everything` would, and deliberately does not
    /// share its channel. The path bar does not merely *render* these titles: an
    /// in-place `git checkout` leaves the cwd alone and moves only the
    /// prompt-embedded title, so `TerminalPathBarView.resolveKey`'s title fields
    /// are the sole signal that a checkout happened (INT-523), and the bar is
    /// `.equatable()`-gated on those same fields. A coalesced channel drops
    /// intermediate values rather than delaying them, and a dropped edge means
    /// `.task(id: resolveKey)` is never re-run at all — so the branch chip, and
    /// the PR and CI lookups keyed off it, would keep naming the pre-checkout
    /// branch indefinitely rather than for a second.
    ///
    /// Cheap to keep fine: this is one view, not the N sidebar rows the profile
    /// attributed the cost to, and the resolve it triggers is already debounced
    /// to the title's settle by `TerminalPathBarResolvePolicy`. That debounce
    /// also only works at the fine cadence — at ~1 Hz the settle delay elapses
    /// every time and the repo walk it exists to suppress would run once a
    /// second instead of never.
    case workspaceAndPaneTitle(TerminalPane.ID)
    /// The workspace title AND every pane title, read from the ~1 Hz COARSE
    /// mirror — the sidebar rows, which render a name and key every pane they
    /// show.
    ///
    /// Only for consumers that render these titles as TEXT. Anything that treats
    /// a title as a signal belongs on a fine case above.
    case everything
}

/// Renders `content` with `sessionID`'s live titles, re-running whenever they
/// change and nothing else.
///
/// Every view that shows a title sits behind `.equatable()`, and a store read
/// made *inside* such a view stales behind that gate (PR #428) — the read has
/// to happen in an ungated body that then hands the value across as a compared
/// input. This is that body, deliberately scoped to a single row / title bar:
/// reading the box one level up (the sidebar section, the pane layout) would
/// re-run every sibling row's construction and the pane layout that owns the
/// Ghostty surface, which is exactly the per-tick invalidation one box per
/// session exists to avoid.
struct LiveTitleScope<Content: View>: View {
    let sessionID: TerminalSession.ID
    /// Narrows which box properties this scope observes, and picks its channel.
    ///
    /// Deliberately has NO default. It used to default to `.everything`, which
    /// was harmless when that only meant "observes both properties" — but
    /// `.everything` now also selects the throttled channel, and the default is
    /// exactly how the path bar ended up on it without anyone choosing that. A
    /// required argument makes the channel a decision every scope has to state.
    var reads: LiveTitleReads
    @ViewBuilder let content: (LiveTitles) -> Content

    @Environment(\.liveTitleBoxProvider) private var boxProvider

    var body: some View {
        // The box's properties are read HERE, so this body — and nothing above
        // it — is what a display-only title write invalidates.
        content(LiveTitles(box: boxProvider(sessionID), reads: reads))
    }
}

/// Resolves a workspace's live-title channel. Defaults to "no channel" so a
/// host that never injects one (tests, previews) renders the session struct's
/// own titles rather than crashing or freezing.
///
/// WARNING — nothing that ticks at title rate may be added to the views that
/// inject this (`ContentView`, `TerminalPaneView`). The environment value is a
/// non-`Equatable` closure, so SwiftUI cannot prove a re-injection is a no-op:
/// every re-render of an injecting view rewrites the environment and re-runs
/// every `LiveTitleScope` below it. That is exactly the sidebar-wide,
/// surface-rehosting invalidation the channel exists to remove (issue #311).
/// State that changes at title rate belongs inside a scope's content, never
/// above the injection point.
private struct LiveTitleBoxProviderKey: EnvironmentKey {
    static let defaultValue: @MainActor (TerminalSession.ID) -> LiveTitleBox? = { _ in nil }
}

extension EnvironmentValues {
    var liveTitleBoxProvider: @MainActor (TerminalSession.ID) -> LiveTitleBox? {
        get { self[LiveTitleBoxProviderKey.self] }
        set { self[LiveTitleBoxProviderKey.self] = newValue }
    }
}

extension View {
    /// Publishes `store`'s live-title channels to every `LiveTitleScope` below.
    ///
    /// `liveTitleBox(for:)` reads only `@ObservationIgnored` store state, so
    /// resolving a box here costs the injecting view no `groups` dependency —
    /// which is the whole point of the channel.
    func liveTitleChannels(from store: SessionStore) -> some View {
        environment(\.liveTitleBoxProvider) { sessionID in
            store.liveTitleBox(for: sessionID)
        }
    }
}
