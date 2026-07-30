import AwesoMuxCore
import SwiftUI

/// A workspace's CURRENT chrome titles, snapshotted out of its `LiveTitleBox`
/// by `LiveTitleScope`.
///
/// A display-only OSC title report writes `SessionStore` group storage
/// *silently* (issue #311), so the `TerminalSession` value a view was handed
/// at its last render can name a title several seconds stale. These are the
/// displayed titles as of this render; the fallbacks keep call sites correct
/// wherever no channel is injected (tests, previews, detached roots), where
/// the struct's own title is by definition the freshest thing available.
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
    /// it does not render. Defaults to both, which is correct-but-coarse — see
    /// `LiveTitleReads` for the narrower cases and what each one buys.
    @MainActor
    init(box: LiveTitleBox?, reads: LiveTitleReads = .everything) {
        switch reads {
        case .workspaceTitle:
            workspace = box?.workspaceTitle
            panes = [:]
        case let .paneTitle(paneID):
            workspace = nil
            // Narrowed to the one entry the content renders. This does NOT
            // narrow the *observation*: `@Observable` publishes per property, so
            // subscripting still registers the whole `paneTitles` dictionary and
            // a sibling pane's tick still re-runs this scope. What it buys is
            // skipping `workspaceTitle` — a workspace rename no longer wakes
            // every pane title bar in the session. Per-pane observation would
            // need per-pane storage on `LiveTitleBox`; revisit only if a
            // many-pane split measures worse than the box redesign.
            panes = (box?.paneTitles[paneID]).map { [paneID: $0] } ?? [:]
        case .everything:
            workspace = box?.workspaceTitle
            panes = box?.paneTitles ?? [:]
        }
    }

    func workspaceTitle(for session: TerminalSession) -> String {
        workspace ?? session.title
    }

    func paneTitle(for pane: TerminalPane) -> String {
        panes[pane.id] ?? pane.title
    }
}

/// Which of `LiveTitleBox`'s two observable properties a scope reads.
///
/// `@Observable` invalidates per property, so this is a real observation
/// boundary and not bookkeeping: the app titlebar renders only the workspace
/// title, and declaring that keeps an INACTIVE pane's spinner from waking it at
/// all. Pick the narrowest case the content can render from.
enum LiveTitleReads: Equatable {
    /// `workspaceTitle` only — the app titlebar.
    case workspaceTitle
    /// One pane's title only — a pane title bar.
    case paneTitle(TerminalPane.ID)
    /// Both, for content that renders the workspace title AND pane titles (a
    /// sidebar row keys every pane; the path bar needs the active pane's title
    /// plus the workspace title as its project fallback).
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
    /// Narrows which box properties this scope observes. Defaults to both, so a
    /// call site that has not thought about it is correct-but-coarse rather than
    /// silently frozen.
    var reads: LiveTitleReads = .everything
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
