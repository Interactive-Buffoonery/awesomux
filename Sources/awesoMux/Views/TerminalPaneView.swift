import AppKit
import AwesoMuxConfig
import AwesoMuxCore
import DesignSystem
import SwiftUI

/// The resolved terminal background color, propagated down the pane tree so the
/// focus stripe (which sits over the terminal surface, whose color is
/// independent of the app chrome — INT-285) can pick a contrast-safe accent.
/// Defaults to the dark Mocha base so previews/tests read sensibly.
private struct TerminalBackgroundColorKey: EnvironmentKey {
    static let defaultValue = Color(red: 30.0 / 255, green: 30.0 / 255, blue: 46.0 / 255)
}

extension EnvironmentValues {
    var terminalBackgroundColor: Color {
        get { self[TerminalBackgroundColorKey.self] }
        set { self[TerminalBackgroundColorKey.self] = newValue }
    }
}

struct TerminalPaneView: View {
    let session: TerminalSession
    let sessionStore: SessionStore
    let ghosttyRuntime: GhosttyRuntime
    let onManagedSSHWorkspaceOffer: ((TerminalSession.ID, TerminalPane.ID) -> Void)?
    /// Whether this pane tree sits directly under the window titlebar (drives
    /// the top-row tab-edge line, #82). Defaults true for the main workspace;
    /// secondary hosts with their own header chrome (floating/companion
    /// panels) pass false or they'd double the header's hairline.
    var abutsWindowTop: Bool = true
    // One drag coordinator per workspace pane tree. Owned here (the tree's entry
    // point) so a drag started on one leaf is visible to the drop overlays on
    // every other leaf; passed down by reference.
    @State private var dragCoordinator = PaneDragCoordinator()

    init(
        session: TerminalSession,
        sessionStore: SessionStore,
        ghosttyRuntime: GhosttyRuntime,
        onManagedSSHWorkspaceOffer: ((TerminalSession.ID, TerminalPane.ID) -> Void)? = nil,
        abutsWindowTop: Bool = true
    ) {
        self.session = session
        self.sessionStore = sessionStore
        self.ghosttyRuntime = ghosttyRuntime
        self.onManagedSSHWorkspaceOffer = onManagedSSHWorkspaceOffer
        self.abutsWindowTop = abutsWindowTop
    }

    var body: some View {
        if ghosttyRuntime.isReady {
            TerminalPaneLayoutView(
                session: session,
                layout: session.layout,
                sessionStore: sessionStore,
                runtime: ghosttyRuntime,
                dragCoordinator: dragCoordinator,
                suppressTopFocusAccentForActivePane: false,
                abutsWindowTop: abutsWindowTop
            )
            .background(Color.aw.surface.terminal)
            // Reading the runtime's resolved background here (not deeper) keeps
            // the @Observable dependency at this layer so the stripe restyles
            // when the terminal theme changes.
            .environment(\.terminalBackgroundColor, Color(nsColor: ghosttyRuntime.terminalBackgroundColor))
            // Backstop reset. The authoritative drag-end signal is the AppKit
            // drag source's `draggingSession(_:endedAt:)` hook (covers drop,
            // cancel, Escape, off-window — see `PaneDragSource`); this is a cheap
            // belt-and-suspenders for the session-switch edge where a drag could
            // outlive its view tree.
            //
            // Keyed on `paneIDs`, NOT `session.layout`: `TerminalPane`'s `==`
            // includes title/cwd, and background agents retitle panes
            // continuously, so keying on the whole layout would let a title tick
            // mid-drag cancel the user's drag. `paneIDs` changes on every
            // move/swap (the order changes) but is immune to title churn.
            .onChange(of: session.layout.paneIDs) { _, _ in
                dragCoordinator.end()
            }
            .task(id: managedSSHOfferIdentity) {
                guard let identity = managedSSHOfferIdentity else { return }
                onManagedSSHWorkspaceOffer?(session.id, identity.paneID)
            }
        } else {
            RuntimeUnavailableView(ghosttyRuntime: ghosttyRuntime)
        }
    }

    private var managedSSHOfferIdentity: ManagedSSHWorkspaceOfferIdentity? {
        guard let pane = session.activePane,
            pane.executionPlan == .local,
            let remoteSSHTarget = pane.remoteSSHTarget
        else {
            return nil
        }
        return ManagedSSHWorkspaceOfferIdentity(
            paneID: pane.id,
            sshDestination: remoteSSHTarget
        )
    }
}

struct ManagedSSHWorkspaceOfferIdentity: Equatable {
    let paneID: TerminalPane.ID
    let sshDestination: String
}

struct TerminalPaneLayoutView: View {
    let session: TerminalSession
    let layout: TerminalPaneLayout
    let sessionStore: SessionStore
    let runtime: GhosttyRuntime
    let dragCoordinator: PaneDragCoordinator
    let suppressTopFocusAccentForActivePane: Bool
    // True for panes in the layout's top row — the ones abutting the window's
    // top chrome (the titlebar, or an interposed banner like needs-input /
    // permission prompts, which still want the edge below them). Drives the
    // inactive tab-edge line (#82). Horizontal splits clear it for their lower
    // child — a line there would double with the split boundary. Secondary
    // hosts opt out via TerminalPaneView's abutsWindowTop parameter.
    var abutsWindowTop: Bool = false
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(AppSettingsStore.self) private var appSettingsStore
    // Read here (an ungated body) and handed to SurfaceProgressBar by value —
    // the bar's .equatable() gate can't be trusted to pass env invalidation.
    @Environment(\.awAccent) private var accentResolver
    // PaneTitleBarView is also behind .equatable(), so accessibility environment
    // state must cross that gate as an explicit value and participate in `==`.
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var isMultiPane: Bool {
        session.layout.hasMultiplePanes
    }

    var body: some View {
        switch layout {
        case let .pane(pane):
            // Mirrors upstream Ghostty's SwiftUI wrapper shape: the geometry
            // seeds the AppKit scroll wrapper, and the nested wrapper's layout
            // pass drives the native surface size. The focus accent and the
            // pane title bar are real VStack rows that RESERVE height (the accent
            // no longer overlays the surface edge, and the title bar never
            // overlaps the terminal — INT-283 F1).
            GeometryReader { _ in
                VStack(spacing: 0) {
                    // Focus indicator band — a constant-height zone reserved on
                    // EVERY pane (focused or not) so the title bar can't bounce
                    // vertically when focus moves (INT-283). Backed by opaque
                    // chrome (matching the title bar) and CLIPPED: when the
                    // reserved space was transparent, a focused neighbour's accent
                    // glow bled through onto the unfocused pane's band (the
                    // right-focused pane draws on top of its left neighbour, so a
                    // bg colour alone can't cover it). Chrome + clip contains each
                    // pane's accent and glow to its own band.
                    ZStack {
                        Color.aw.surface.chrome
                        if session.activePaneID == pane.id,
                            !suppressTopFocusAccentForActivePane
                        {
                            PaneFocusAccent(
                                state: session.focusAccentAwState,
                                differentiateWithoutColor: differentiateWithoutColor
                            )
                        } else if abutsWindowTop {
                            // Top-row inactive panes draw the tab-edge line that
                            // replaced the titlebar hairline (#82) — without it the
                            // workspace title blends into the pane title strip.
                            // Top-aligned so its top pixel row matches the focus
                            // accent's; lower panes get separation from the split
                            // divider instead.
                            VStack(spacing: 0) {
                                Rectangle()
                                    .fill(Color.aw.border2)
                                    .frame(height: 1)
                                Spacer(minLength: 0)
                            }
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                        }
                    }
                    .frame(height: PaneFocusAccent.reservedHeight)
                    .clipped()

                    if isMultiPane {
                        PaneTitleBarView(
                            session: session,
                            pane: pane,
                            sessionStore: sessionStore,
                            dragCoordinator: dragCoordinator,
                            runtime: runtime,
                            reduceTransparency: reduceTransparency
                        )
                        // Skip re-render when this bar's inputs are unchanged —
                        // a sibling-pane retitle re-evaluates this whole tree.
                        .equatable()
                    }

                    // Nested GeometryReader so the surface gets its TRUE remaining
                    // size for the AppKit PTY — the accent thickness is dynamic,
                    // so manual height math would be fragile.
                    GeometryReader { surfaceProxy in
                        GhosttySurfaceRepresentable(
                            session: session,
                            pane: pane,
                            sessionStore: sessionStore,
                            runtime: runtime,
                            enabledAgentRuntimeFileDropSources: AgentRuntimeConsent.enabledFileDropSources(
                                from: appSettingsStore.agentIntegrations.value
                            ),
                            grokIconEnabled: appSettingsStore.agentIntegrations.value.grok.enabled,
                            contentSize: surfaceProxy.size,
                            // Reading the @Observable revision here subscribes
                            // this pane subtree to orphan-rescue nudges — see
                            // GhosttyRuntime.noteOrphanedSurfaceView (INT-600).
                            remountNudge: runtime.surfaceRemountNudgeRevision
                        )
                        .overlay {
                            if appSettingsStore.appearance.value.crtScanlines {
                                CRTScanlinesOverlay()
                            }
                        }
                        .overlay {
                            // Dim every pane that isn't the active one so the
                            // focused surface reads at a glance. A single-pane
                            // session never hits this branch (its one pane is
                            // always active), so the dim only appears once a
                            // split exists.
                            if session.activePaneID != pane.id {
                                InactivePaneScrim()
                            }
                        }
                        .overlay(alignment: .bottom) {
                            if let progressReport = pane.progressReport,
                                progressReport.isVisible
                            {
                                // Accent passed by value so it participates in
                                // the bar's `==` — see SurfaceProgressBar.accent.
                                SurfaceProgressBar(
                                    report: progressReport,
                                    accent: accentResolver.accent
                                )
                                // Skip re-render when the report is
                                // unchanged — same reasoning as
                                // `PaneTitleBarView.equatable()` above:
                                // a sibling pane's update shouldn't
                                // re-evaluate this one.
                                .equatable()
                            }
                        }
                        .overlay(alignment: .topTrailing) {
                            SurfaceSearchOverlay(runtime: runtime, paneID: pane.id)
                        }
                        // Opaque cover for a remote pane whose bridge died
                        // (INT-697). Gated on `remoteReconnect != nil` alone —
                        // NOT a live `remoteTarget` lookup — so a latched pane
                        // moved to a different (or local) group keeps its
                        // overlay instead of reverting to the blank surface
                        // `errorLatched` still blocks from recreating.
                        .overlay {
                            if let remoteReconnect = pane.remoteReconnect {
                                RemotePaneDisconnectedView(
                                    state: remoteReconnect,
                                    liveTarget: pane.executionPlan.remoteTarget,
                                    runtime: runtime,
                                    paneID: pane.id,
                                    paneDescriptor: TerminalAccessibilityAnnouncer.paneDescriptor(
                                        for: pane.id,
                                        in: session
                                    )
                                )
                            }
                        }
                        // The pane's drag source now lives in the title bar
                        // (PaneTitleBarView hosts PaneDragSource as the drag
                        // handle), so there's no separate corner grab glyph over
                        // the surface anymore (INT-283 Task 7).
                    }
                }
                // Drop zones cover the WHOLE pane stack (title bar + surface),
                // not just the surface — otherwise a drag released over another
                // pane's title bar finds no drop target and cancels. Attached to
                // the VStack, gated to the non-dragged panes exactly as before:
                // appears over every pane EXCEPT the one being dragged, only
                // while a pane drag is in flight. The dragged pane shows no
                // overlay (no self-drop target); the drag's end is handled
                // authoritatively by the AppKit drag source, so no reset catcher
                // is needed over the origin pane.
                .overlay {
                    if dragCoordinator.isDragging,
                        dragCoordinator.draggedPaneID != pane.id
                    {
                        PaneDropZonesOverlay(
                            targetPaneID: pane.id,
                            sessionID: session.id,
                            sessionStore: sessionStore,
                            coordinator: dragCoordinator
                        )
                    }
                }
            }

        case let .split(split):
            TerminalSplitLayoutView(
                session: session,
                split: split,
                sessionStore: sessionStore,
                runtime: runtime,
                dragCoordinator: dragCoordinator,
                suppressTopFocusAccentForActivePane: suppressTopFocusAccentForActivePane,
                abutsWindowTop: abutsWindowTop
            )

        case let .documentGroup(group):
            // The group leaf is the session's single document viewer: tab strip
            // (INT-748 PR2) over the selected tab's rendered document. The
            // strip's per-tab close X and the send-to-agent button are real
            // NSButtons with refusesFirstResponder so they never steal focus
            // from the terminal surface across the split (INT-562 PR1/PR2).
            // `selectedTab` is non-nil for every reducer-built group; a
            // hand-edited snapshot with a bad selection clamps at decode, so
            // the `if let` is belt-and-suspenders rather than a real code path.
            if let selectedTab = group.selectedTab {
                DocumentGroupView(
                    document: selectedTab,
                    group: group,
                    session: session,
                    sessionStore: sessionStore,
                    runtime: runtime
                )
                // Document groups sit outside the focus-accent band, so a
                // top-row group draws the tab-edge line itself — without it
                // the titlebar would blend straight into the tab strip now
                // that the titlebar hairline is gone (#82).
                .overlay(alignment: .top) {
                    if abutsWindowTop {
                        Rectangle()
                            .fill(Color.aw.border2)
                            .frame(height: 1)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
            }
        }
    }
}
