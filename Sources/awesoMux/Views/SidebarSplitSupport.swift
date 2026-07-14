import AwesoMuxCore
import AwesoMuxConfig
import CoreGraphics
import Foundation
import Observation

enum SidebarHostMode: Equatable {
    case persistent(width: CGFloat)
    case hidden
    case overlay(width: CGFloat)
}

enum SidebarPresentationCommand: Equatable {
    case showOverlay
    case hideOverlay
    case showPersistent
}

enum SidebarPresentationRouting {
    static func command(
        userWantsHidden: Bool,
        proximity: SidebarPresentationModel.ProximityState
    ) -> SidebarPresentationCommand {
        guard userWantsHidden else { return .showPersistent }
        return proximity == .revealed ? .showOverlay : .hideOverlay
    }
}

@Observable
@MainActor
final class SidebarHostPresentationState {
    private(set) var mode: SidebarHostMode
    private(set) var effectiveVisibleWidth: CGFloat
    @ObservationIgnored var onSettleForTesting: (() -> Void)?

    init(mode: SidebarHostMode = .persistent(width: SidebarWidthPolicy.expandedWidth)) {
        self.mode = mode
        switch mode {
        case let .persistent(width), let .overlay(width): effectiveVisibleWidth = width
        case .hidden: effectiveVisibleWidth = 0
        }
    }

    func settle(mode: SidebarHostMode, effectiveVisibleWidth: CGFloat) {
        self.mode = mode
        self.effectiveVisibleWidth = effectiveVisibleWidth
        onSettleForTesting?()
    }
}

enum SidebarHostHandoffAction: Equatable {
    case beginNoActionsTransaction
    case cancelOverlayGeneration
    case captureSidebarResponder
    case removeOverlayAnimation
    case reparentHostToSplitContainer
    case setPersistentState
    case applySingleDividerIntent(CGFloat)
    case settleLayout
    case clearTransform
    case hideOverlayContainer
    case restoreSidebarResponder
    case endNoActionsTransaction
}

enum SidebarPhysicalEdge: Equatable {
    case leading
    case trailing
}

enum SidebarPeekDirection: Equatable {
    case left
    case right
}

enum AppTitlebarColumn: Equatable {
    case sidebar
    case detail
}

enum AppTitlebarLockupAlignment: Equatable {
    case leading
    case trailing
}

struct SidebarPresentationLayoutPolicy {
    let position: AppearanceConfig.SidebarPosition

    var edge: SidebarPhysicalEdge { position == .left ? .leading : .trailing }
    var peekDirection: SidebarPeekDirection { position == .left ? .right : .left }
    var titlebarColumns: [AppTitlebarColumn] {
        position == .left ? [.sidebar, .detail] : [.detail, .sidebar]
    }
    var trafficLightColumn: AppTitlebarColumn { titlebarColumns[0] }
    var dividerGutterColumn: AppTitlebarColumn { position == .left ? .detail : .sidebar }
    var dividerGutterEdge: SidebarPhysicalEdge { .leading }
    var titlebarLockupAlignment: AppTitlebarLockupAlignment {
        position == .left ? .leading : .trailing
    }
    var titlebarLockupOuterPadding: CGFloat { AppTitlebarMetrics.lockupPadding }
}

/// Live sidebar width published on every divider tick (INT-535, A4).
///
/// Scoped deliberately: only the titlebar and the sidebar pane read `value`, so a
/// drag re-renders just those two — NOT `ContentView`'s body or the terminal pane
/// (which would re-host per frame). The persisted `sidebarWidth` `@State` updates
/// only on commit (drag end), so band-derived layout can switch live during a drag
/// while persistence stays discrete.
@Observable
@MainActor
final class SidebarLiveWidth {
    var value: CGFloat
    init(value: CGFloat) { self.value = value }
}

/// The collapsed-rail hover peek card, lifted out of the sidebar pane (INT-535).
///
/// Once the sidebar became an `NSHostingController` pane inside the native
/// `NSSplitView`, that pane clips its content to its own bounds, so the old
/// in-tile overlay could no longer overflow the ~60pt rail onto the terminal
/// (INT-533 regression). The card now renders as a `ContentView`-level overlay
/// *above* the split. A hovered tile publishes which session is peeked and its
/// vertical position here; `ContentView` reads it and draws the card.
///
/// `anchorY`/`tileHeight` are measured in the sidebar pane's SwiftUI `.global`
/// space. That root spans the whole window, titlebar included (the rail draws
/// behind the transparent titlebar), while the peek overlay's local space
/// starts below the titlebar — so these coordinates must NOT be used as
/// overlay positions directly. `SidebarPeekCardOverlay` converts them by
/// subtracting its own measured `.global` origin. An earlier same-origin
/// assumption here silently broke when window-chrome work changed the
/// titlebar inset and every card drifted down by titlebar height (INT-790).
/// The subtraction handles the overlay's side dynamically, but still assumes
/// this sidebar root spans the whole window: if the sidebar ever becomes
/// titlebar-inset too, the overlay would over-correct and the card would
/// float titlebar-height too high — re-derive the mapping then.
@Observable
@MainActor
final class SidebarPeekModel {
    private(set) var session: TerminalSession?
    private(set) var location: SidebarSessionLocation?
    private(set) var tint: ProjectTint?
    /// Pre-walked per-pane rows for the multi-pane card (INT-538). Rebuilt in
    /// `show`/`refresh` so a pane added/closed or a per-pane state change while
    /// hovering repaints. Empty for a single-pane workspace (card shows the
    /// summary instead).
    private(set) var paneItems: [PanePeekItem] = []

    /// Group-roster peek state — mutually exclusive with `session` above.
    /// `showGroup` clears `session`/`location`/`paneItems`; `show` clears
    /// these. Only one card (session or group) is ever displayed.
    private(set) var group: SessionGroup?
    private(set) var groupSessionItems: [SessionPeekItem] = []

    private(set) var anchorY: CGFloat = 0
    private(set) var tileHeight: CGFloat = 0
    /// The hovered row's right edge in the split's `.global` space. The card's
    /// leading edge anchors just past this, so it floats right of the rail when
    /// collapsed AND right of the full-width row when expanded — one anchor,
    /// both modes (INT-538 expanded support).
    private(set) var anchorX: CGFloat = 0
    private(set) var peekDirection: SidebarPeekDirection = .right
    @ObservationIgnored private var anchorFrame: CGRect = .zero

    /// Routes a pane-row click up to `ContentView` (select workspace + focus
    /// pane + acknowledge). Set once when the overlay is installed — the same
    /// shape as `SidebarSplitProxy.setWidth` — so hover churn doesn't re-thread
    /// it. Takes the session ID so the handler doesn't depend on `session` still
    /// being the same one by the time the click lands.
    @ObservationIgnored var onSelectPane: ((TerminalSession.ID, TerminalPane.ID) -> Void)?

    /// Routes a group-roster row click up to `ContentView` (select
    /// workspace + focus its active pane). Set once when the overlay is
    /// installed, same shape as `onSelectPane`. Carries the invoking group's
    /// ID too — a VoiceOver "Jump to X" action can fire for a DIFFERENT
    /// group than whichever peek happens to be showing (e.g. group A's card
    /// is still open inside its hide grace when a VoiceOver action fires for
    /// group B), so the handler must target the group the action actually
    /// came from, not `group?.id` read off the model at call time.
    @ObservationIgnored var onSelectGroupSession: ((SessionGroup.ID, TerminalSession.ID) -> Void)?

    /// True while the pointer rests over the (hittable) multi-pane card. Gates
    /// the graced hide so the card can't vanish under a cursor reaching for a
    /// row (538 R5). `@ObservationIgnored` — it drives the hide timer, not the
    /// rendered card, so it must not invalidate the overlay.
    @ObservationIgnored private var isPointerOverCard = false
    /// INVARIANT: every method that mutates `session` (`show`/`hide`) and every
    /// pointer-transition entry point cancels this task *before* changing state.
    /// That cancel is the whole safety mechanism — it's why a stale grace fire
    /// can't hide a card a newer `show` just put up. The task closes over the
    /// schedule-time `id` and `hide(for:)` re-guards on it, so even a missed
    /// cancel no-ops against a different session rather than hiding the wrong
    /// card. `refresh` deliberately does NOT cancel: a content refresh while the
    /// pointer is mid-gap should not extend the grace (the pointer is leaving).
    @ObservationIgnored private var hideGraceTask: Task<Void, Never>?
    /// Seam for the grace wait (INT-557): tests inject a controllable gate so
    /// the 220ms grace "elapses" on command instead of racing real wall-clock
    /// sleeps under parallel test scheduling. Production uses the real sleep.
    @ObservationIgnored private let sleep: @Sendable (Duration) async -> Void

    init(sleep: @Sendable @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.sleep = sleep
    }

    func show(
        session: TerminalSession,
        location: SidebarSessionLocation,
        tint: ProjectTint,
        frame: CGRect,
        position: AppearanceConfig.SidebarPosition = .left
    ) {
        hideGraceTask?.cancel()
        hideGraceTask = nil
        // Reset the pointer flag on takeover: if tile B's `show` wins before the
        // old card A's `onHover(false)` lands, A's late false event no-ops on the
        // session-id guard and would otherwise leave `isPointerOverCard == true`
        // stuck — permanently blocking B's `requestHide` at the `!isPointerOverCard`
        // gate, stranding B's card open (Codex 538 review).
        isPointerOverCard = false
        group = nil
        groupSessionItems = []
        self.session = session
        self.location = location
        self.tint = tint
        self.paneItems = PanePeekItem.items(for: session)
        anchorY = frame.minY
        tileHeight = frame.height
        updateAnchor(frame: frame, position: position)
    }

    /// Keep the card tracking its tile as the rail scrolls or resizes. No-op
    /// unless the given tile currently owns the peek, so a non-hovered tile's
    /// geometry churn can't yank the card.
    func updateFrame(
        for id: TerminalSession.ID,
        frame: CGRect,
        position: AppearanceConfig.SidebarPosition = .left
    ) {
        guard session?.id == id else { return }
        anchorY = frame.minY
        tileHeight = frame.height
        updateAnchor(frame: frame, position: position)
    }

    /// Refresh the displayed content if this tile owns the peek. The model holds
    /// a session *snapshot*, so without this a title/cwd/agent-state change while
    /// hovering would leave the card stale (the old in-tile card re-rendered with
    /// the row). Id-guarded like the others.
    func refresh(session: TerminalSession, location: SidebarSessionLocation, tint: ProjectTint) {
        guard self.session?.id == session.id else { return }
        self.session = session
        self.location = location
        self.tint = tint
        self.paneItems = PanePeekItem.items(for: session)
    }

    /// Clear only if this tile owns the peek — guards the hover hand-off
    /// (entering tile's `show` can land before the leaving tile's `hide`).
    func hide(for id: TerminalSession.ID) {
        guard session?.id == id else { return }
        hideGraceTask?.cancel()
        hideGraceTask = nil
        isPointerOverCard = false
        session = nil
        location = nil
        tint = nil
        paneItems = []
    }

    /// The pointer entered (`over == true`) or left the hittable multi-pane
    /// card. Entering cancels a pending graced hide so the card persists while
    /// the user reaches for a row; leaving requests a graced hide (538 R5).
    func setPointerOverCard(_ over: Bool, for id: TerminalSession.ID) {
        guard session?.id == id else { return }
        isPointerOverCard = over
        if over {
            hideGraceTask?.cancel()
            hideGraceTask = nil
        } else {
            requestHide(for: id)
        }
    }

    /// Hide after a short grace covering the tile→card pointer gap. The card is
    /// offset right of the rail, so while crossing the gap the pointer is over
    /// neither tile nor card; an immediate hide there would dismiss the card
    /// mid-reach. If the pointer lands on the card during the grace,
    /// `setPointerOverCard(true:)` cancels this (538 R5).
    func requestHide(for id: TerminalSession.ID) {
        guard session?.id == id else { return }
        hideGraceTask?.cancel()
        // `sleep` captured by value, self stays weak and unwraps only after the
        // wait — the pending grace must not extend the model's lifetime.
        hideGraceTask = Task { @MainActor [weak self, sleep] in
            await sleep(.milliseconds(220))
            guard !Task.isCancelled, let self, !self.isPointerOverCard else { return }
            self.hide(for: id)
        }
    }

    func showGroup(
        group: SessionGroup,
        tint: ProjectTint,
        sessions: [TerminalSession],
        activeSessionID: TerminalSession.ID?,
        frame: CGRect,
        position: AppearanceConfig.SidebarPosition = .left
    ) {
        hideGraceTask?.cancel()
        hideGraceTask = nil
        isPointerOverCard = false
        session = nil
        location = nil
        paneItems = []
        self.group = group
        self.tint = tint
        groupSessionItems = SessionPeekItem.items(for: sessions, activeSessionID: activeSessionID)
        anchorY = frame.minY
        tileHeight = frame.height
        updateAnchor(frame: frame, position: position)
    }

    /// Keep the card tracking its header as the rail scrolls or resizes.
    /// No-op unless the given group currently owns the peek.
    func updateGroupFrame(
        for id: SessionGroup.ID,
        frame: CGRect,
        position: AppearanceConfig.SidebarPosition = .left
    ) {
        guard group?.id == id else { return }
        anchorY = frame.minY
        tileHeight = frame.height
        updateAnchor(frame: frame, position: position)
    }

    func hideAll() {
        hideGraceTask?.cancel()
        hideGraceTask = nil
        isPointerOverCard = false
        session = nil
        location = nil
        group = nil
        tint = nil
        paneItems = []
        groupSessionItems = []
    }

    func updatePosition(_ position: AppearanceConfig.SidebarPosition) {
        updateAnchor(frame: anchorFrame, position: position)
    }

    private func updateAnchor(frame: CGRect, position: AppearanceConfig.SidebarPosition) {
        anchorFrame = frame
        let policy = SidebarPresentationLayoutPolicy(position: position)
        peekDirection = policy.peekDirection
        anchorX = position == .left ? frame.maxX : frame.minX
    }

    /// Refresh the displayed content if this group owns the peek — same
    /// staleness problem `refresh(session:...)` solves one level down.
    func refreshGroup(
        group: SessionGroup,
        tint: ProjectTint,
        sessions: [TerminalSession],
        activeSessionID: TerminalSession.ID?
    ) {
        guard self.group?.id == group.id else { return }
        self.group = group
        self.tint = tint
        groupSessionItems = SessionPeekItem.items(for: sessions, activeSessionID: activeSessionID)
    }

    /// Clear only if this group owns the peek — guards the hover hand-off,
    /// same as `hide(for:)`.
    func hideGroup(for id: SessionGroup.ID) {
        guard group?.id == id else { return }
        hideGraceTask?.cancel()
        hideGraceTask = nil
        isPointerOverCard = false
        group = nil
        tint = nil
        groupSessionItems = []
    }

    /// Pointer entered/left the hittable group-roster card — same grace
    /// cancel/request shape as `setPointerOverCard(_:for:)`.
    func setPointerOverGroupCard(_ over: Bool, for id: SessionGroup.ID) {
        guard group?.id == id else { return }
        isPointerOverCard = over
        if over {
            hideGraceTask?.cancel()
            hideGraceTask = nil
        } else {
            requestHideGroup(for: id)
        }
    }

    /// Hide after the same short grace `requestHide(for:)` uses, covering
    /// the header→card pointer gap.
    func requestHideGroup(for id: SessionGroup.ID) {
        guard group?.id == id else { return }
        hideGraceTask?.cancel()
        hideGraceTask = Task { @MainActor [weak self, sleep] in
            await sleep(.milliseconds(220))
            guard !Task.isCancelled, let self, !self.isPointerOverCard else { return }
            self.hideGroup(for: id)
        }
    }
}

/// Lets `ContentView` command the native divider position (for the `⌘\` toggle)
/// without holding the `NSSplitViewController` directly. The controller registers
/// its setter in `makeNSViewController`; reading/calling `command` does not create
/// an observation dependency, so invoking it never re-renders `ContentView`.
@Observable
@MainActor
final class SidebarSplitProxy {
    /// Set by `SidebarSplitView.makeNSViewController`. Moves the divider so the
    /// sidebar pane is the given width (clamped, un-animated).
    @ObservationIgnored var setSelectedWidth: ((CGFloat) -> Void)?
    @ObservationIgnored var setOverlayVisible: ((Bool, SidebarOverlayTransition, Bool) -> Void)?
    @ObservationIgnored var setPosition: ((AppearanceConfig.SidebarPosition) -> Void)?
    /// Changes only the user's persistent split visibility. Transient hover
    /// presentation must use the overlay host instead of moving this divider.
    @ObservationIgnored var setPersistentVisible: ((Bool) -> Void)?
}
