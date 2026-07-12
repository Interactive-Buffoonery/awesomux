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
    @State private var dragStartFraction: Double?
    @State private var dragFraction: Double?
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let fraction = dragFraction ?? split.firstFraction

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
            // Keyed on `focusAccentAwState` (not the raw rollup) so an
            // acknowledge-pending pane keeps its peach rail too (INT-721).
            let dividerAbsorbsTopAccent =
                split.orientation == .horizontal
                && split.second.isSinglePane
                && split.second.contains(paneID: session.activePaneID)
                && session.focusAccentAwState != .needs
            // Equal to `focusAccentAwState` in this branch (absorb requires it to
            // be non-`.needs`, which means no ack fold is active).
            let dividerFocusState: AwState? =
                dividerAbsorbsTopAccent ? session.chromeAwState : nil

            switch split.orientation {
            case .vertical:
                HStack(spacing: 0) {
                    firstLayout
                        .frame(width: max(0, size.width * fraction - SplitDivider.layoutThickness / 2))

                    SplitDivider(
                        orientation: .vertical,
                        currentFraction: fraction,
                        focusAccentState: nil
                    ) { translation in
                        resize(using: translation.width, availableLength: size.width)
                    } onEnded: {
                        commitResize()
                    } onAdjust: { delta in
                        sessionStore.resizeSplit(
                            id: split.id,
                            firstFraction: split.firstFraction + delta,
                            in: session.id
                        )
                    }

                    secondLayout
                        .frame(width: max(0, size.width * (1 - fraction) - SplitDivider.layoutThickness / 2))
                }

            case .horizontal:
                VStack(spacing: 0) {
                    firstLayout
                        .frame(height: max(0, size.height * fraction - SplitDivider.layoutThickness / 2))

                    SplitDivider(
                        orientation: .horizontal,
                        currentFraction: fraction,
                        focusAccentState: dividerFocusState
                    ) { translation in
                        resize(using: translation.height, availableLength: size.height)
                    } onEnded: {
                        commitResize()
                    } onAdjust: { delta in
                        sessionStore.resizeSplit(
                            id: split.id,
                            firstFraction: split.firstFraction + delta,
                            in: session.id
                        )
                    }

                    layoutView(
                        split.second,
                        suppressTopFocusAccentForActivePane: dividerAbsorbsTopAccent
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

    private func layoutView(
        _ layout: TerminalPaneLayout,
        suppressTopFocusAccentForActivePane: Bool? = nil
    ) -> some View {
        TerminalPaneLayoutView(
            session: session,
            layout: layout,
            sessionStore: sessionStore,
            runtime: runtime,
            dragCoordinator: dragCoordinator,
            suppressTopFocusAccentForActivePane: suppressTopFocusAccentForActivePane
                ?? self.suppressTopFocusAccentForActivePane
        )
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
                Color.clear
                    .frame(
                        width: orientation == .vertical ? Self.hitTargetThickness : nil,
                        height: orientation == .horizontal ? Self.hitTargetThickness : nil
                    )
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                onDrag(value.translation)
                            }
                            .onEnded { _ in
                                onEnded()
                            }
                    )
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
