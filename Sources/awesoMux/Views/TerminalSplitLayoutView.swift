import AppKit
import AwesoMuxConfig
import AwesoMuxCore
import DesignSystem
import SwiftUI

struct TerminalSplitLayoutView: View {
    let session: TerminalSession
    let split: TerminalSplit
    let sessionStore: SessionStore
    let runtime: GhosttyRuntime
    let dragCoordinator: PaneDragCoordinator
    let suppressTopFocusAccentForActivePane: Bool
    // See TerminalPaneLayoutView.abutsWindowTop (#82).
    var abutsWindowTop: Bool = false
    private struct PrimaryDrag {
        let token: UUID
        let mount: PrimaryPaneTree.Mount
        let splitID: TerminalSplit.ID
        let startFraction: Double
        var fraction: Double
    }

    @Environment(\.primaryPaneTreeContext) private var primaryContext
    @State private var primaryDrag: PrimaryDrag?
    @State private var dragStartFraction: Double?
    @State private var dragFraction: Double?
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let fraction = displayedFraction

            // When the active pane sits directly below a horizontal-split
            // divider, the divider absorbs the focus highlight — one line,
            // not a grey divider stacked with the pane's top accent. The
            // suppression flag and the divider focus state MUST share this
            // predicate. `isSinglePane` clamps to the leaf case so ancestor
            // dividers in nested splits don't also light up.
            //
            // Other configurations (`.first`-active, or any vertical split)
            // have no adjacency between the pane's top accent and the
            // divider — no absorption needed; the top accent stands alone.
            //
            // `.needs` is the exception: the divider can't carry the thicker,
            // glowing escalation (and goes neutral under Increase Contrast), so
            // letting it absorb a needs rail would hide the attention cue for a
            // bottom-of-horizontal-split pane. Keep the loud rail on the pane.
            // Keyed on the active pane's OWN `focusAccentAwState(for:)` (not the
            // session fold) so only that pane's unacknowledged attention blocks
            // the absorb — a needy sibling elsewhere paints its own rail instead.
            let activePaneAccentState = session.focusAccentAwState(
                forPaneID: session.activePaneID
            )
            let dividerAbsorbsTopAccent =
                split.orientation == .horizontal
                && split.second.isSinglePane
                && split.second.contains(paneID: session.activePaneID)
                && activePaneAccentState != .needs
            // The absorbed rail carries the active pane's state (absorb requires
            // it to be non-`.needs`, so this never paints the escalation hue).
            let dividerFocusState: AwState? =
                dividerAbsorbsTopAccent ? activePaneAccentState : nil

            switch split.orientation {
            case .vertical:
                HStack(spacing: 0) {
                    firstLayout
                        .frame(width: max(0, size.width * fraction - SplitDivider.layoutThickness / 2))

                    verticalDividerColumn(size: size)
                        .zIndex(dividerZIndex)

                    secondLayout
                        .frame(width: max(0, size.width * (1 - fraction) - SplitDivider.layoutThickness / 2))
                }

            case .horizontal:
                VStack(spacing: 0) {
                    firstLayout
                        .frame(height: max(0, size.height * fraction - SplitDivider.layoutThickness / 2))

                    divider(availableLength: size.height, focusAccentState: dividerFocusState)
                        .zIndex(dividerZIndex)

                    layoutView(
                        split.second,
                        suppressTopFocusAccentForActivePane: dividerAbsorbsTopAccent,
                        abutsWindowTop: false
                    )
                    .frame(height: max(0, size.height * (1 - fraction) - SplitDivider.layoutThickness / 2))
                }
            }
        }
        .onChange(of: split.id) { _, _ in
            resetDrag()
        }
    }

    private var firstLayout: some View {
        layoutView(split.first)
    }

    private var secondLayout: some View {
        layoutView(split.second)
    }

    /// A vertical divider in the top row gets a chrome cap the height of the
    /// pane focus band, carrying the same top-aligned tab-edge line — so the
    /// divider terminates at the tab edge instead of poking toward the
    /// titlebar (the hairline that used to terminate it is gone, #82), and
    /// the edge line reads as one continuous stroke across panes and divider.
    @ViewBuilder
    private func verticalDividerColumn(size: CGSize) -> some View {
        let divider = divider(availableLength: size.width, focusAccentState: nil)
        if abutsWindowTop {
            VStack(spacing: 0) {
                // Continue the tab-edge line across the divider column; the
                // divider band rises to meet it. (A band-height chrome cap was
                // tried first and left a dark notch at the top of every
                // top-row divider once the edge line moved to the top of the
                // band — the divider itself is the right filler below the
                // line, #82.)
                Rectangle()
                    .fill(Color.aw.border2)
                    .frame(width: SplitDivider.layoutThickness, height: 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                divider
            }
        } else {
            divider
        }
    }

    private func layoutView(
        _ layout: TerminalPaneLayout,
        suppressTopFocusAccentForActivePane: Bool? = nil,
        abutsWindowTop: Bool? = nil
    ) -> some View {
        TerminalPaneLayoutView(
            session: session,
            layout: layout,
            sessionStore: sessionStore,
            runtime: runtime,
            dragCoordinator: dragCoordinator,
            suppressTopFocusAccentForActivePane: suppressTopFocusAccentForActivePane
                ?? self.suppressTopFocusAccentForActivePane,
            abutsWindowTop: abutsWindowTop ?? self.abutsWindowTop
        )
    }

    // Keep the AppKit grab area (which extends past the one-point footprint)
    // in front of both adjacent panes for hit testing.
    private var dividerZIndex: Double { primaryContext == nil ? 0 : 1 }

    private var displayedFraction: Double {
        if let primaryContext, let primaryDrag, primaryDrag.splitID == split.id,
            primaryContext.currentMount == primaryDrag.mount,
            primaryContext.tree.ownsDrag(primaryDrag.token, splitID: split.id, mount: primaryDrag.mount)
        {
            return primaryDrag.fraction
        }
        return dragFraction ?? split.firstFraction
    }

    private func divider(availableLength: CGFloat, focusAccentState: AwState?) -> some View {
        let primaryInput = primaryContext.map { context in
            let mount = context.currentMount
            return PrimarySplitDividerInput(
                mount: mount,
                splitID: split.id,
                begin: { token in
                    beginPrimaryDrag(token, mount: mount, context: context, availableLength: availableLength)
                },
                change: { token, translation in
                    changePrimaryDrag(token, translation: translation, availableLength: availableLength, context: context)
                },
                end: { token, commit in
                    endPrimaryDrag(token, commit: commit, mount: mount, context: context)
                }
            )
        }
        return SplitDivider(
            orientation: split.orientation,
            currentFraction: displayedFraction,
            focusAccentState: focusAccentState,
            primaryInput: primaryInput
        ) { translation in
            resize(using: split.orientation == .vertical ? translation.width : translation.height, availableLength: availableLength)
        } onEnded: {
            commitResize()
        } onAdjust: { delta in
            sessionStore.resizeSplit(
                id: split.id,
                firstFraction: split.firstFraction + delta,
                in: session.id
            )
        }
    }

    private func beginPrimaryDrag(
        _ token: UUID, mount: PrimaryPaneTree.Mount?, context: PrimaryPaneTreeContext, availableLength: CGFloat
    ) -> Bool {
        guard availableLength.isFinite, availableLength > SplitDivider.layoutThickness,
            let mount, context.currentMount == mount,
            let currentSplit = sessionStore.session(id: session.id)?.layout.split(id: split.id),
            currentSplit.orientation == split.orientation,
            context.tree.beginDrag(token, splitID: split.id, mount: mount)
        else { return false }
        primaryDrag = PrimaryDrag(
            token: token, mount: mount, splitID: split.id,
            startFraction: currentSplit.firstFraction, fraction: currentSplit.firstFraction
        )
        return true
    }

    private func changePrimaryDrag(
        _ token: UUID, translation: CGSize, availableLength: CGFloat, context: PrimaryPaneTreeContext
    ) -> Bool {
        guard var drag = primaryDrag, drag.token == token else { return false }
        let distance = split.orientation == .vertical ? translation.width : translation.height
        guard availableLength.isFinite, availableLength > SplitDivider.layoutThickness,
            context.currentMount == drag.mount,
            context.tree.ownsDrag(token, splitID: split.id, mount: drag.mount),
            sessionStore.session(id: session.id)?.layout.split(id: split.id)?.orientation == split.orientation
        else { return false }
        drag.fraction = (drag.startFraction + Double(distance / availableLength)).clampedSplitFraction
        primaryDrag = drag
        return true
    }

    private func endPrimaryDrag(
        _ token: UUID, commit: Bool, mount: PrimaryPaneTree.Mount?, context: PrimaryPaneTreeContext
    ) {
        guard let mount else { return }
        defer { context.tree.endDrag(token, splitID: split.id, mount: mount) }
        guard let drag = primaryDrag, drag.token == token, drag.mount == mount, drag.splitID == split.id else { return }
        if commit, context.currentMount == drag.mount,
            context.tree.ownsDrag(token, splitID: split.id, mount: drag.mount),
            let currentSplit = sessionStore.session(id: session.id)?.layout.split(id: split.id),
            currentSplit.orientation == split.orientation, currentSplit.firstFraction != drag.fraction
        {
            sessionStore.resizeSplit(id: split.id, firstFraction: drag.fraction, in: session.id)
        }
        primaryDrag = nil
    }

    private func resize(using translation: CGFloat, availableLength: CGFloat) {
        guard availableLength > SplitDivider.layoutThickness else {
            resetDrag()
            return
        }

        if translation == 0 || dragStartFraction == nil {
            dragStartFraction = split.firstFraction
        }

        let startFraction = dragStartFraction ?? split.firstFraction
        let nextFraction = startFraction + Double(translation / availableLength)
        dragFraction = nextFraction.clampedSplitFraction
    }

    private func commitResize() {
        if let dragFraction {
            sessionStore.resizeSplit(
                id: split.id,
                firstFraction: dragFraction,
                in: session.id
            )
        }

        resetDrag()
    }

    private func resetDrag() {
        dragStartFraction = nil
        dragFraction = nil
    }
}
private extension Double {
    var clampedSplitFraction: Double {
        guard isFinite else {
            return 0.5
        }

        return min(max(self, 0.15), 0.85)
    }
}

private struct SplitDivider: View {
    // The painted divider always slightly overflows its layout footprint, so it
    // covers the inter-pane boundary with zero gap in EVERY state, rest included.
    // The footprint used to be 6pt with a 2pt band centered in it, leaving ~4pt
    // of the channel showing the pane background (`surface.terminal` = the app
    // theme base); against a mismatched terminal bg (e.g. a dark terminal in
    // Latte app mode) that sliver read as a white "window chrome" seam. Now the
    // footprint (1pt) is narrower than the resting band (2pt), so the band
    // overflows ~0.5pt onto each adjacent pane edge — no pane-background sliver
    // can show through, robust even against sub-pixel pane-edge rounding, and
    // independent of the terminal bg (which awesoMux can't read in Ghostty-config
    // mode — INT-285). Hover/focus bands (3pt / 4pt) overflow more, same idea.
    // The footprint stays constant across states, so panes never reflow. The
    // 16pt hit target is a separate, non-layout overlay.
    static let layoutThickness: CGFloat = 1
    private static let hitTargetThickness: CGFloat = 16
    private static let visualThickness: CGFloat = 2
    private static let hoverVisualThickness: CGFloat = 3

    let orientation: TerminalSplitOrientation
    let currentFraction: Double
    let focusAccentState: AwState?
    let primaryInput: PrimarySplitDividerInput?
    let onDrag: (CGSize) -> Void
    let onEnded: () -> Void
    let onAdjust: (Double) -> Void
    @State private var isHovering = false
    @FocusState private var isKeyboardFocused: Bool
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.awAccent) private var accentResolver
    @Environment(\.terminalBackgroundColor) private var terminalBackground
    // OS "Increase Contrast" — the divider tokens have dedicated HC variants
    // because the standard hexes sit close to the 1.4.11 floor.
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        RoundedRectangle(cornerRadius: activeVisualThickness / 2)
            .fill(dividerColor)
            .frame(
                width: orientation == .vertical ? activeVisualThickness : nil,
                height: orientation == .horizontal ? activeVisualThickness : nil
            )
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 0.15),
                value: activeVisualThickness
            )
            .frame(
                width: orientation == .vertical ? Self.layoutThickness : nil,
                height: orientation == .horizontal ? Self.layoutThickness : nil
            )
            .overlay {
                // The hit target is wider than the visible divider so the
                // resize gesture has a generous grab area. The overlay does
                // not participate in layout, so the parent HStack/VStack
                // still allocates only `layoutThickness` for the divider —
                // matching what the surrounding panes subtract.
                hitTarget
                    .onHover { hovering in
                        // Guard against redundant callbacks — SwiftUI can
                        // re-fire `.onHover` with the same value on
                        // hierarchy mutations, which would double-push or
                        // double-pop the NSCursor stack.
                        guard hovering != isHovering else { return }
                        isHovering = hovering
                        // `NSCursor.set()` makes the cursor current but has
                        // no auto-reset on hover-out — the resize glyph
                        // would stay stuck until another element re-set it.
                        // `push` / `pop` is the idiomatic AppKit pattern
                        // for "temporarily override the cursor while
                        // pointer is inside X."
                        if hovering {
                            cursor.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .onDisappear {
                        // `.onHover(false)` is NOT guaranteed when the view
                        // is removed from the hierarchy while hovered (per
                        // Apple's docs — the closure fires when the pointer
                        // enters or exits the frame, but a vanished frame
                        // produces no exit event). A pane split or close
                        // mid-hover would otherwise leak an unbalanced
                        // `push()` on the cursor stack.
                        if isHovering {
                            NSCursor.pop()
                            isHovering = false
                        }
                    }
            }
            .focusable()
            .focused($isKeyboardFocused)
            // Plain keyboard arrow-key resize. Mirrors the VoiceOver
            // adjustable action below so sighted keyboard-only users
            // (who don't drive the AX rotor) can resize splits too.
            // Direction is orientation-aware: vertical divider responds
            // to left/right, horizontal divider to up/down.
            .onKeyPress(.leftArrow) {
                guard orientation == .vertical else { return .ignored }
                onAdjust(-0.05)
                return .handled
            }
            .onKeyPress(.rightArrow) {
                guard orientation == .vertical else { return .ignored }
                onAdjust(0.05)
                return .handled
            }
            .onKeyPress(.upArrow) {
                guard orientation == .horizontal else { return .ignored }
                onAdjust(-0.05)
                return .handled
            }
            .onKeyPress(.downArrow) {
                guard orientation == .horizontal else { return .ignored }
                onAdjust(0.05)
                return .handled
            }
            .accessibilityElement()
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue("\(Int(currentFraction * 100)) percent")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    onAdjust(0.05)
                case .decrement:
                    onAdjust(-0.05)
                @unknown default:
                    break
                }
            }
    }

    @ViewBuilder
    private var hitTarget: some View {
        let target = Color.clear
            .frame(
                width: orientation == .vertical ? Self.hitTargetThickness : nil,
                height: orientation == .horizontal ? Self.hitTargetThickness : nil
            )
            .contentShape(Rectangle())
        if let primaryInput {
            target.overlay {
                PrimarySplitDividerDrag(input: primaryInput)
            }
        } else {
            target.gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { onDrag($0.translation) }
                    .onEnded { _ in onEnded() }
            )
        }
    }

    // Keyboard focus is treated as equivalent to mouse hover for the
    // visual escalation — without this, a keyboard-only user pressing
    // arrow keys to resize a divider gets no visual confirmation that
    // their input is being received by the divider (vs eaten by some
    // other focus owner).
    private var isInteractionFocused: Bool {
        isHovering || isKeyboardFocused
    }

    private var activeVisualThickness: CGFloat {
        // When the divider absorbs the active-pane focus cue it stands in for
        // the suppressed top stripe, but unlike the stripe it competes with the
        // divider's own 3pt hover state — so it must stay STRICTLY above hover,
        // never dropping to the light-terminal 3pt stripe thickness. Otherwise
        // an HC user (who keeps the neutral divider color) on a light terminal
        // sees focus and hover as identical 3pt neutral lines and loses the
        // non-color focus signal. 4pt non-DWC / 6pt DWC clears hover in all cases.
        if focusAccentState != nil {
            return differentiateWithoutColor ? 6 : 4
        }

        return isInteractionFocused ? Self.hoverVisualThickness : Self.visualThickness
    }

    private var dividerColor: Color {
        // Under "Increase Contrast", use the neutral HC-tuned tokens. HC users
        // get maximum legibility (neutral, not chromatic); focus is still
        // signaled via the thickness bump in `activeVisualThickness`.
        if colorSchemeContrast == .increased {
            return isInteractionFocused ? Color.aw.dividerHoverHC : Color.aw.dividerRestHC
        }

        // Active pane sits directly below this divider — divider becomes
        // the focus highlight (replacing what would otherwise be the pane's
        // top accent stripe sitting just below the divider). Full bright accent
        // + glow, so it out-pops the resting divider below.
        if let focusAccentState {
            return PaneFocusStyle.color(
                for: focusAccentState,
                accent: accentResolver.accent,
                terminalBackground: terminalBackground
            )
        }

        // At rest / on hover: a muted, contrast-tuned version of the app accent
        // (`AwAccent.dividerHex` — desaturated, holds the 1.4.11 floor). Neutral
        // gray here read as an OS window-chrome seam, worst in Latte.
        return Color.aw.dividerAccent(accentResolver.accent, focused: isInteractionFocused)
    }

    private var accessibilityLabel: String {
        switch orientation {
        case .vertical:
            "Vertical pane divider"
        case .horizontal:
            "Horizontal pane divider"
        }
    }

    private var cursor: NSCursor {
        switch orientation {
        case .vertical:
            NSCursor.resizeLeftRight
        case .horizontal:
            NSCursor.resizeUpDown
        }
    }
}
