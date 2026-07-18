import AwesoMuxConfig
import AwesoMuxCore
import DesignSystem
import Foundation
import SwiftUI

struct SidebarSessionTile: View {
    let session: TerminalSession
    let match: SessionMatch?
    let tint: ProjectTint
    let isActive: Bool
    let displayMode: SidebarWidthMode
    let isKeyboardFocused: Bool
    let showsSearchFocusCue: Bool
    let jumpIndex: Int?
    let hasBackgroundedFloatingWork: Bool
    let isPromotedInsertion: Bool
    let isPromotionPulseActive: Bool
    let isFiltering: Bool
    let duplicateDisambiguation: SidebarDuplicateDisambiguation?
    let indexInGroup: Int
    let sessionCountInGroup: Int
    /// Index of this workspace's owning group within `SessionStore.groups`.
    /// Kept for diagnostics / future expansion.
    let ownerGroupIndex: Int
    /// Adjacent groups in the sidebar — drive bounded VoiceOver actions.
    let previousNeighborGroup: SessionGroup?
    let nextNeighborGroup: SessionGroup?
    /// All other groups (excluding the owner) for the context-menu picker.
    let otherGroups: [SessionGroup]
    let verticalPadding: CGFloat
    let onSelect: () -> Void
    let onNewSessionHere: () -> Void
    let onAcknowledge: () -> Void
    let onMoveWithinGroup: (Int) -> Void
    let onMoveToGroup: (SessionGroup.ID) -> Void
    let onClose: () -> Void
    let onClear: () -> Void
    let onRename: () -> Void
    let canMakeWorkspaceManaged: Bool
    let onMakeWorkspaceManaged: () -> Void
    let onToggleNotificationsMute: () -> Void
    let isPinned: Bool
    let onTogglePin: () -> Void
    /// Origin group name spoken to VoiceOver when this tile renders in the
    /// synthetic Pinned section — the audible twin of the pointer-only origin
    /// tooltip. `nil` (the default) for in-group tiles, which have no separate
    /// origin to announce (INT-737).
    var pinnedOriginGroupName: String? = nil
    let onDragStarted: () -> UUID
    let focusedRowTarget: FocusState<SidebarVisibleRowTarget?>.Binding
    /// Snapshot of the sidebar's keyboard-modality flag at construction —
    /// what `renderKey` compares and what the focus-ring gate below reads.
    /// The OLD/NEW tile instances compared by `==` share the SAME
    /// `@Binding`, so a read through the binding's live getter sees the
    /// CURRENT value on both operands regardless of which value was current
    /// when either instance was built — the comparison is permanently
    /// equal and the field is inert. A plain `Bool` captured per-instance
    /// doesn't have that problem.
    let isKeyboardNavigatingValue: Bool
    /// Write-only plumbing: every read of keyboard-navigation state goes
    /// through `isKeyboardNavigatingValue` above. This binding exists solely
    /// so the tap handler and hover handler can clear keyboard-modality
    /// state on a pointer-modality signal; it is deliberately excluded from
    /// `RenderKey` (see the doc comment there) since a binding's identity
    /// isn't comparable and its value is write-only from this view's side.
    @Binding var isKeyboardNavigating: Bool

    @State private var isHovered = false
    @State private var promotionPulseIsBright = false
    @State private var promotionPulseTask: Task<Void, Never>?
    @State private var isPeekVisible = false
    @State private var peekTask: Task<Void, Never>?
    /// This row's box in the sidebar pane's `.global` space — handed to the
    /// `SidebarPeekModel` so `ContentView` can draw the peek card aligned with
    /// the tile, above the split. See `SidebarPeekModel`.
    @State private var tileFrame: CGRect = .zero
    @Environment(SidebarPeekModel.self) private var peekModel
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppSettingsStore.self) private var appSettingsStore
    // Published from SidebarView.body onto the collapsed rail; relies on this
    // tile being a descendant of the sidebar (always true). Defaults to false.
    @Environment(\.isCommandKeyHeld) private var isCommandKeyHeld

    /// The row plus its styling, gestures, focus, drag, and hover/peek
    /// tracking. Split out of `body` so the type-checker can handle each half
    /// of the modifier chain on its own — the combined chain times out.
    ///
    /// Plain View + `.onTapGesture` instead of `Button(action:)` — SwiftUI's
    /// Button on macOS claims the press gesture before `.draggable` can start a
    /// drag (skill `swiftui-macos-draggable-on-button-silent-fail`). `.draggable`
    /// sits immediately after `.contentShape` and before `.onTapGesture` /
    /// `.contextMenu` / accessibility actions so it wins gesture priority. The
    /// always-on below-tile jump digit is added via `.safeAreaInset` (in `body`)
    /// rather than wrapping the row — a wrapper changes the root view and broke
    /// the hover peek escape. `tileContent` stays the root.
    @ViewBuilder
    private func interactiveTile(
        location: SidebarSessionLocation,
        rollup: SessionAgentRollup
    ) -> some View {
        tileContent(location: location, rollup: rollup)
            .padding(.horizontal, displayMode == .collapsed ? 0 : 10)
            .padding(.vertical, displayMode == .collapsed ? 0 : verticalPadding)
            .background(tileBackground)
            .overlay(tileBorder(rollup: rollup))
            .overlay(promotionPulseOverlay)
            .overlay(alignment: .leading) { activeRail }
            .awGlow(color: tint.hue.opacity(isActive ? 0.24 : 0), radius: 8)
            .contentShape(Rectangle())
            // Plain `.focusable()` (all interactions) is load-bearing: with
            // interactions restricted to `.activate`, programmatic
            // `focusedRowTarget` writes are silently DROPPED whenever the
            // system-wide "Keyboard navigation" setting is off (the macOS
            // default), killing sidebar keyboard nav. Verified with a probe
            // app (INT-652). The INT-652 click-focus fix lives in the tap
            // handler below instead.
            .focusable()
            .focused(focusedRowTarget, equals: .session(session.id))
            // Suppress the macOS system focus ring (the always-on blue outline
            // on the selected/focused row); the accent `awFocusRing` below is our
            // keyboard-focus indicator and is gated to keyboard navigation.
            .focusEffectDisabled()
            .awFocusRing(
                showsSearchFocusCue || (isKeyboardFocused && isKeyboardNavigatingValue),
                cornerRadius: AwRadius.panel
            )
            // `.simultaneousGesture(TapGesture)` instead of `.onTapGesture`
            // — see group header for rationale (tap-exclusive blocks drag
            // activation on macOS).
            .simultaneousGesture(
                TapGesture().onEnded {
                    isKeyboardNavigating = false
                    // INT-652: the mouseDown parked focus on this row (click-to-
                    // focus). `onSelect` hands first responder to the terminal
                    // directly, so the row won't keep KEYBOARD focus — but the
                    // SwiftUI focus target would go stale (next arrow-key nav
                    // resuming from this row while a different workspace is
                    // selected). A click is a pointer-modality signal: clear it.
                    focusedRowTarget.wrappedValue = nil
                    onSelect()
                }
            )
            .onDrag {
                let dragID = onDragStarted()
                let provider = NSItemProvider()
                registerSidebarDragPayload(
                    WorkspaceDragItem(sessionID: session.id, dragID: dragID),
                    on: provider
                )
                return provider
            }
            // Sibling overlay — avoids nested Button hit-test ambiguity.
            .overlay(alignment: .trailing) { closeButton }
            .overlay { jumpNumberOverlay }
            // The peek card no longer lives here — it renders as a ContentView
            // overlay above the split (the rail pane clips to its bounds). We
            // only measure this row's frame where the peek can appear: the
            // collapsed rail (any workspace) and expanded multi-pane rows
            // (INT-538 expanded support). Single-pane expanded rows skip the
            // `.global` resolve — pure waste, the inline row already shows all.
            .background {
                if canPeek {
                    Color.clear
                        .onGeometryChange(for: CGRect.self) { proxy in
                            proxy.frame(in: .global)
                        } action: {
                            tileFrame = $0
                        }
                }
            }
            .onHover { hovering in
                isHovered = hovering
                // Moving the pointer over a row is a pointer-modality signal —
                // hide the keyboard focus ring (it reappears on the next arrow).
                if hovering {
                    isKeyboardNavigating = false
                }
                updatePeekVisibility()
            }
            .onChange(of: isKeyboardFocused) { _, _ in
                updatePeekVisibility()
            }
            .onChange(of: displayMode) { _, _ in
                // Re-evaluate on a ⌘\ toggle even when the pointer never moves:
                // a single-pane peek must dismiss when the rail expands (the
                // full-width row restates it), while a multi-pane peek stays and
                // re-anchors to the now-wider row's edge. `updatePeekVisibility`'s
                // `canPeek` gate handles both.
                updatePeekVisibility()
            }
            .onChange(of: isPeekVisible) { _, visible in
                if visible {
                    peekModel.show(
                        session: session,
                        location: location,
                        tint: tint,
                        frame: tileFrame,
                        position: appSettingsStore.appearance.value.sidebarPosition
                    )
                } else if session.layout.paneCount > 1 {
                    // Multi-pane card is hittable — graced hide so the pointer
                    // can cross the rail→card gap to reach a row without the
                    // card vanishing (538 R5). The card's own hover cancels it.
                    peekModel.requestHide(for: session.id)
                } else {
                    peekModel.hide(for: session.id)
                }
            }
            .onChange(of: tileFrame) { _, frame in
                peekModel.updateFrame(
                    for: session.id,
                    frame: frame,
                    position: appSettingsStore.appearance.value.sidebarPosition
                )
            }
            .onChange(of: session.peekRefreshKey) { _, _ in
                // Keep a live peek's content fresh — agent state / title / cwd can
                // change while the pointer rests on the rail tile. Keyed on the
                // peek's render projection, NOT `session` equality, so a shell
                // idle↔busy flip (excluded from `==`) still refreshes the card (S4).
                peekModel.refresh(session: session, location: session.sidebarLocation, tint: tint)
            }
            .onDisappear {
                isHovered = false
                cancelPeek()
                promotionPulseTask?.cancel()
                promotionPulseTask = nil
                peekModel.hide(for: session.id)
            }
            .transition(promotedInsertionTransition)
    }

    var body: some View {
        let location = session.sidebarLocation
        // One rollup walk per render: the icon, chrome state, border, and
        // accessibility label all derive from the same winning pane. Computing
        // it once here (instead of in `tileContent`, `tileBorder`, and
        // `rowAccessibilityLabel` separately) also keeps the three reads on a
        // single `now`, so a state that flips mid-render can't render
        // inconsistently across them.
        let rollup = session.agentRollup()
        // Keep the context-menu and inset expressions separate. Combining this
        // modifier chain exceeds Swift's type-checking budget for the view.
        let tile = interactiveTile(location: location, rollup: rollup)
            .contextMenu {
                contextMenuContent
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(rowAccessibilityLabel(location: location, rollup: rollup))
            .accessibilityValue(rowAccessibilityValue)
            .accessibilityAddTraits(.isButton)
            .accessibilityAddTraits(isActive ? [.isSelected] : [])
            // Default VoiceOver activation (VO+space). Refactoring off
            // `Button(action: onSelect)` to free `.onDrag` removed the
            // built-in button activation, so without this the row's primary
            // "select this workspace" action is unreachable for assistive
            // tech users — they can invoke rename/close/new (named actions
            // below) but not the row's main purpose. Match the same fix on
            // the group header.
            .accessibilityAction { onSelect() }
            .accessibilityAction(named: "Rename Workspace") {
                onRename()
            }
            .accessibilityAction(named: "Close Workspace") {
                onClose()
            }
            .accessibilityAction(named: "Clear Workspace") {
                onClear()
            }
            .accessibilityAction(named: "New Workspace Here") {
                onNewSessionHere()
            }
            .accessibilityAction(named: muteMenuTitle) {
                onToggleNotificationsMute()
            }
            .accessibilityAction(named: pinMenuTitle) {
                onTogglePin()
            }
            .accessibilityActions {
                // Per-pane jump targets — the keyboard/VoiceOver parity for the
                // mouse-only hover peek card (538 R3). The card is a transient
                // floating overlay unreachable by assistive tech; these named
                // actions on the focusable tile give every pane a reachable jump.
                // Reuse the same wired closure the card's row clicks use, so select
                // + focus + per-pane ack stays identical across mouse and VoiceOver.
                if session.layout.paneCount > 1 {
                    ForEach(PanePeekItem.items(for: session)) { item in
                        Button(paneJumpActionLabel(item)) {
                            peekModel.onSelectPane?(session.id, item.id)
                        }
                    }
                }
                // Reorder actions are suppressed during filter, matching the
                // drag/drop gating. `indexInGroup` here counts the filtered
                // entries (not the full `group.sessions`), so a Move Up/Down
                // under filter would mutate the underlying array against an
                // index from the projected view — landing the workspace at
                // the wrong slot relative to hidden rows.
                if !isFiltering, indexInGroup > 0 {
                    Button("Move Workspace Up") {
                        onMoveWithinGroup(indexInGroup - 1)
                    }
                }
                if !isFiltering, indexInGroup < sessionCountInGroup - 1 {
                    Button("Move Workspace Down") {
                        // moveSession's atIndex is post-removal, so "down by one"
                        // in current visible terms maps to indexInGroup + 1.
                        onMoveWithinGroup(indexInGroup + 1)
                    }
                }
                // Bounded "previous / next group" only — avoids the N×groups
                // rotor explosion. Full routing lives in the context menu's
                // "Move to Group…" submenu for mouse users; VoiceOver users
                // can also use the submenu via the context menu rotor.
                if !isFiltering, let previousGroup = previousNeighborGroup {
                    Button("Move to Previous Group (\(previousGroup.name))") {
                        onMoveToGroup(previousGroup.id)
                    }
                }
                if !isFiltering, let nextGroup = nextNeighborGroup {
                    Button("Move to Next Group (\(nextGroup.name))") {
                        onMoveToGroup(nextGroup.id)
                    }
                }
            }
        let accessibleTile = managedConversionAccessibilityAction(tile)
        // Always-on jump digit below the tile (collapsed + setting on). Uses
        // safeAreaInset so it adds layout below without wrapping the row root.
        let insetTile = accessibleTile.safeAreaInset(edge: .bottom, spacing: 0) {
            jumpNumberBelow
        }

        return
            insetTile
            .onChange(of: isPromotionPulseActive, initial: true) { _, active in
                updatePromotionPulse(active: active)
            }
    }

    @ViewBuilder
    private var contextMenuContent: some View {
        Button("New Workspace Here") {
            onNewSessionHere()
        }

        Button("Rename Workspace...") {
            onRename()
        }

        Button("Make Active Pane Managed…") {
            onMakeWorkspaceManaged()
        }
        .disabled(!canMakeWorkspaceManaged)

        if session.unreadNotificationCount > 0 || session.needsAcknowledgement {
            Button("Acknowledge Workspace") {
                onAcknowledge()
            }
        }

        Button(muteMenuTitle) {
            onToggleNotificationsMute()
        }

        Button(pinMenuTitle) {
            onTogglePin()
        }

        if !otherGroups.isEmpty {
            Divider()

            Menu("Move to Group…") {
                ForEach(otherGroups, id: \.id) { other in
                    Button(other.name) {
                        onMoveToGroup(other.id)
                    }
                }
            }
        }

        Divider()

        Button("Close Workspace", role: .destructive) {
            onClose()
        }

        // Separated: Close is undoable (reopen), Clear is permanent —
        // don't let two same-styled destructive rows sit shoulder to
        // shoulder for a misclick (INT-282).
        Divider()

        Button("Clear Workspace", role: .destructive) {
            onClear()
        }
    }

    @ViewBuilder
    private func managedConversionAccessibilityAction<Content: View>(_ content: Content) -> some View {
        if canMakeWorkspaceManaged {
            content.accessibilityAction(named: "Make Active Pane Managed…") {
                onMakeWorkspaceManaged()
            }
        } else {
            content
        }
    }

    /// Context-menu title and named accessibility action for the per-workspace
    /// notification mute toggle (INT-598). One string for both so mouse and
    /// VoiceOver users see the same verb.
    private var muteMenuTitle: String {
        session.notificationsMuted
            ? String(
                localized: "Unmute Notifications",
                comment: "Sidebar workspace context-menu action that re-enables macOS notifications for the workspace.")
            : String(
                localized: "Mute Notifications",
                comment: "Sidebar workspace context-menu action that silences macOS notifications for the workspace.")
    }

    /// Context-menu title and named accessibility action for pinning this
    /// workspace to the top of the sidebar (INT-737). One string for both so
    /// mouse and VoiceOver users see the same verb.
    private var pinMenuTitle: String {
        isPinned
            ? String(
                localized: "Unpin",
                comment:
                    "Sidebar workspace context-menu action that removes the workspace from the pinned section, returning it to its group.")
            : String(localized: "Pin", comment: "Sidebar workspace context-menu action that pins the workspace to the top of the sidebar.")
    }

    /// Whether this row can show a peek card at all, independent of hover.
    /// Collapsed rail: any workspace (summary or multi-pane list). Expanded:
    /// only multi-pane workspaces — the full-width single-pane row already
    /// shows everything inline, so a card there would just restate it.
    private var canPeek: Bool {
        displayMode == .collapsed || session.layout.paneCount > 1
    }

    private func updatePeekVisibility() {
        guard canPeek,
            isHovered || isKeyboardFocused
        else {
            cancelPeek()
            return
        }

        guard !isPeekVisible else {
            return
        }

        peekTask?.cancel()
        peekTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else {
                return
            }
            if reduceMotion {
                isPeekVisible = true
            } else {
                withAnimation(.easeOut(duration: 0.12)) {
                    isPeekVisible = true
                }
            }
        }
    }

    private func cancelPeek() {
        peekTask?.cancel()
        peekTask = nil
        guard isPeekVisible else {
            return
        }
        if reduceMotion {
            isPeekVisible = false
        } else {
            withAnimation(.easeOut(duration: 0.08)) {
                isPeekVisible = false
            }
        }
    }

    private func tileContent(
        location: SidebarSessionLocation,
        rollup: SessionAgentRollup
    ) -> some View {
        HStack(spacing: 10) {
            AgentTile(
                agent: rollup.winningAgentKind.awAgentIcon,
                state: rollup.state.awState,
                // Collapsed: the colored tile fills the full 40pt rail box
                // (no inset ring); expanded keeps the 32pt list-row icon.
                size: displayMode == .collapsed ? 40 : 32,
                badgeStyle: displayMode == .collapsed ? .collapsed : .full
            )
            .equatable()

            // Collapsed rail shows the icon only — no room for a title in a
            // 40pt column, and the centered icon must own the row so it sits
            // concentric with the selection border.
            if displayMode == .expanded {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        titleText
                            .awFont(AwFont.UI.label)
                            .lineLimit(1)

                        if rollup.unreadTotal > 0 {
                            NotificationBadge(count: rollup.unreadTotal)
                        }
                    }

                    if displayMode == .expanded || isActive {
                        HStack(spacing: 6) {
                            if session.layout.paneCount > 1 {
                                Text("▮▮ \(session.layout.paneCount)")
                                    .awFont(AwFont.Mono.meta)
                                    .foregroundStyle(Color.aw.text)
                            }

                            if displayMode == .expanded {
                                locationMetadata(location: location)

                                if let duplicateDisambiguation {
                                    Text(duplicateDisambiguation.visibleLabel)
                                        .awFont(AwFont.Mono.meta)
                                        .foregroundStyle(Color.aw.text)
                                        .lineLimit(1)
                                        .fixedSize(horizontal: true, vertical: false)
                                        .layoutPriority(1)
                                }
                            }
                        }
                    }
                }
            }

            // Expanded-only: in collapsed the centered icon owns the row, so no
            // trailing spacer that would shove it off-center.
            if displayMode == .expanded {
                Spacer(minLength: 4)
            }

            // Collapsed mode conveys needs via the AgentTile badge and crowds
            // these 6pt dots in the 40pt row, so they render expanded-only.
            if displayMode == .expanded {
                if session.notificationsMuted {
                    // Muted state is spoken via rowAccessibilityLabel; the
                    // glyph is the sighted user's cue that banners/sound are
                    // off for this workspace while indicators stay live.
                    Image(systemName: "bell.slash")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.aw.text2)
                        .help("Notifications muted for this workspace")
                        .accessibilityHidden(true)
                }

                if hasBackgroundedFloatingWork {
                    // Teal-family status token signals "you have a hidden floating
                    // panel running work for this workspace." Stock `teal` fails
                    // Latte 1.4.11 against the tile (2.43:1); `status.floatingWork`
                    // is contrast-tuned. The dot is the sole visual carrier for
                    // sighted users; rowAccessibilityLabel is the sole carrier for
                    // assistive technology. Clears on re-summon.
                    Circle()
                        .fill(Color.aw.status.floatingWork)
                        .frame(width: 6, height: 6)
                        .help("Floating panel has running work in the background")
                        .accessibilityHidden(true)
                }

                if rollup.state.awState == .needs {
                    Circle()
                        .fill(Color.aw.status.needs)
                        .frame(width: 6, height: 6)
                        // State is already spoken via rowAccessibilityLabel;
                        // this dot is decorative, so hide it from VoiceOver.
                        .accessibilityHidden(true)
                }
            }

            if displayMode == .expanded {
                // Reserve trailing space for the sibling close button (overlay).
                Color.clear.frame(width: 20, height: 20)
            }
        }
        .frame(width: displayMode == .collapsed ? 40 : nil)
    }

    /// Title text — rendered as a highlighted AttributedString when the title
    /// was the matched haystack, plain Text otherwise. Base color is baked
    /// into the AttributedString so search-match emphasis keeps an accessible
    /// foreground instead of falling back to a lower-contrast accent token.
    private var titleText: Text {
        if let match, match.field == .title {
            Text(highlighted(session.title, ranges: match.ranges, base: Color.aw.text))
        } else {
            Text(session.title)
                .foregroundStyle(Color.aw.text)
        }
    }

    @ViewBuilder
    private func locationMetadata(location: SidebarSessionLocation) -> some View {
        if location.kind == .remote {
            Image(systemName: "network")
                .awFont(AwFont.Mono.meta)
                .foregroundStyle(Color.aw.text)
                .accessibilityHidden(true)
        }

        locationText(location: location)
            .awFont(AwFont.Mono.meta)
            .lineLimit(1)
    }

    private func locationText(location: SidebarSessionLocation) -> Text {
        // Keep sidebar row metadata on the primary text token. In Latte,
        // `text2` (subtext0) does not clear AA even against the untinted
        // elevated surface; hierarchy here comes from font/position, not a
        // lower-contrast color.
        let displayText = location.displayText
        if let match, match.field == .location {
            return Text(highlighted(displayText, ranges: match.ranges, base: Color.aw.text))
        }
        return Text(displayText)
            .foregroundStyle(Color.aw.text)
    }

    private func highlighted(
        _ source: String,
        ranges: [Range<String.Index>],
        base: Color
    ) -> AttributedString {
        var attr = AttributedString(source)
        attr.foregroundColor = base
        for range in ranges {
            guard let lower = AttributedString.Index(range.lowerBound, within: attr),
                let upper = AttributedString.Index(range.upperBound, within: attr)
            else {
                // Range provenance and AttributedString construction agree on
                // the same backing string today; if this ever fires we've
                // broken that contract and want the signal in development.
                assertionFailure("Highlight range out of AttributedString bounds — provenance broke.")
                continue
            }
            attr[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
        }
        return attr
    }

    @ViewBuilder
    private var activeRail: some View {
        // Decorative chrome, not the load-bearing selection cue. The rail uses
        // the bright `tint.hue` (not the contrast-tuned `borderHue`), so in Latte
        // it can sit below 3:1 against the sidebar for some accents — that's fine.
        // WCAG 1.4.11 is carried by `tileBorder`; do not "fix" the rail to match.
        let isHighContrast = contrast == .increased
        // Collapsed selection is carried by the thickened tinted border ring
        // (tileBorder), so the rail bar is expanded-only — no empty collapsed
        // branch.
        if isActive, displayMode != .collapsed {
            RoundedRectangle(cornerRadius: 2)
                .fill(tint.hue)
                .frame(width: isHighContrast ? 4 : 2)
                .padding(.vertical, isHighContrast ? 6 : 8)
                .offset(x: -1)
                .awGlow(color: tint.hue.opacity(0.7), radius: 5)
        }
    }

    @ViewBuilder
    private var closeButton: some View {
        if displayMode == .expanded {
            SidebarCloseButton(onClose: onClose)
        }
    }

    @ViewBuilder
    private var jumpNumberOverlay: some View {
        if jumpNumberDisplay == .overlay,
            let jumpIndex,
            (1...9).contains(jumpIndex)
        {
            // Fill the whole tile footprint with a near-opaque scrim that
            // matches the tile-background shape, so the digit cleanly REPLACES
            // the icon during ⌘-hold instead of floating translucently over it
            // (the icon was poking out past a smaller 32pt translucent box).
            RoundedRectangle(cornerRadius: AwRadius.panel)
                .fill(Color.aw.surface.elevated.opacity(0.97))
                .overlay {
                    Text("\(jumpIndex)")
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.aw.text)
                }
                .transition(reduceMotion ? .identity : .opacity)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var jumpNumberBelow: some View {
        if jumpNumberDisplay == .belowTile,
            let jumpIndex,
            (1...9).contains(jumpIndex)
        {
            Text("\(jumpIndex)")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                // railText (not text2/text3): the digit is small and functional
                // on the mantle rail, so it needs to clear AA in both themes.
                // Stock text2 is 4.06:1 in Latte.
                .foregroundStyle(Color.aw.railText)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
                .accessibilityHidden(true)
        }
    }

    private var jumpNumberDisplay: JumpNumberDisplay {
        JumpNumberDisplay.resolve(
            collapsed: displayMode == .collapsed,
            alwaysOn: appSettingsStore.appearance.value.alwaysShowJumpNumbers,
            commandHeld: isCommandKeyHeld
        )
    }

    private var tileBackground: some View {
        RoundedRectangle(cornerRadius: AwRadius.panel)
            .fill(Color.aw.surface.elevated)
            .overlay {
                RoundedRectangle(cornerRadius: AwRadius.panel)
                    .fill(Color.aw.surface.hover.opacity(isHovered && !isActive ? 1 : 0))
            }
    }

    private func tileBorder(rollup: SessionAgentRollup) -> some View {
        // Active selection must present a 3:1 non-text cue (WCAG 1.4.11) in
        // BOTH contrast modes: the glow is dropped under increased contrast
        // (see AwGlowModifier) and the tint rail is decorative chrome, so the
        // border carries selection on its own. `border`/`border2` are
        // `text.opacity(…)` and top out ~1.4:1 against the tile interior — the
        // opaque divider tokens are the ones measured to clear 3:1 (INT-299).
        // Idle tiles stay on the quiet `border`: the default state needs no
        // state cue, only the active/needs states do.
        //
        // The active border carries the workspace tint via `tintBorder`, which
        // is contrast-tuned per theme. Increased-contrast keeps the measured
        // gray `dividerHoverHC`: that path deliberately strips decoration (glow
        // is already dropped) to maximize legibility, and the gray is the value
        // verified for the 2pt HC stroke. See INT-490.
        let isHighContrast = contrast == .increased
        let needsAttention = rollup.state.awState == .needs
        let strokeColor: Color = {
            if needsAttention && !isActive {
                return Color.aw.status.needs.opacity(isHighContrast ? 0.95 : 0.50)
            }
            if isActive {
                return isHighContrast ? Color.aw.dividerHoverHC : tint.borderHue
            }
            if isHighContrast {
                // Resting HC border clears 3:1 on the resting tile, but Latte
                // drops to 2.84:1 once surface.hover composites under it.
                // Hovered HC tiles step up to dividerHoverHC (3.59:1); active
                // already uses that token at a thicker stroke. F44 / INT-480.
                return isHovered ? Color.aw.dividerHoverHC : Color.aw.dividerRestHC
            }
            return Color.aw.border
        }()
        let lineWidth: CGFloat = {
            if isActive {
                if isHighContrast { return 2.0 }
                return displayMode == .collapsed ? 1.5 : 0.75
            }
            return isHighContrast ? 1.0 : 0.5
        }()
        // A color-independent cue for the unselected needs row: peach can also
        // be an explicit workspace tint, so a solid peach border would still
        // collide with a peach selection. Dashing never matches the solid
        // selection stroke, and survives the collapsed rail (INT-287) where the
        // rail/glow that otherwise disambiguates is gone. See INT-491.
        // ponytail: dash pattern tuned on-screen, one knob here.
        let needsDash: [CGFloat] = [3, 2]
        let strokeStyle =
            needsAttention && !isActive
            ? StrokeStyle(lineWidth: lineWidth, dash: needsDash)
            : StrokeStyle(lineWidth: lineWidth)
        return RoundedRectangle(cornerRadius: AwRadius.panel)
            .stroke(strokeColor, style: strokeStyle)
    }

    private var promotionPulseOverlay: some View {
        RoundedRectangle(cornerRadius: AwRadius.panel)
            .inset(by: 2)
            .stroke(
                Color.aw.peach.opacity(promotionPulseIsBright ? 0.9 : 0),
                lineWidth: promotionPulseIsBright ? 2 : 0
            )
            .awGlow(
                color: Color.aw.peach.opacity(promotionPulseIsBright ? 0.55 : 0),
                radius: promotionPulseIsBright ? 10 : 0
            )
    }

    private var promotedInsertionTransition: AnyTransition {
        guard isPromotedInsertion, !reduceMotion else {
            return .identity
        }
        return .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .identity
        )
    }

    private func updatePromotionPulse(active: Bool) {
        // Cancel any in-flight fade-out first: an inactive->active flip (or a
        // reuse of this row) must not have a stale hold-then-dim task fire
        // later and blank a pulse that's meant to be lit.
        promotionPulseTask?.cancel()
        promotionPulseTask = nil

        let motion = FloatingPanelPromotionMotion.resolved(reduceMotion: reduceMotion)

        guard active else {
            if reduceMotion {
                promotionPulseIsBright = false
            } else {
                withAnimation(.easeOut(duration: motion.pulseOutDuration)) {
                    promotionPulseIsBright = false
                }
            }
            return
        }

        if reduceMotion {
            promotionPulseIsBright = true
            return
        }

        withAnimation(.easeOut(duration: motion.pulseInDuration)) {
            promotionPulseIsBright = true
        }
        promotionPulseTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(motion.pulseInDuration))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: motion.pulseOutDuration)) {
                promotionPulseIsBright = false
            }
        }
    }

    private func rowAccessibilityLabel(
        location: SidebarSessionLocation,
        rollup: SessionAgentRollup
    ) -> String {
        var parts = [
            Self.workspaceIdentityAccessibilityLabel(session: session, rollup: rollup),
            locationAccessibilityLabel(location: location),
        ]

        if session.layout.paneCount > 1 {
            parts.append("\(session.layout.paneCount) panes")
        }

        if rollup.unreadTotal > 0 {
            parts.append(LocalizedPluralStrings.sidebarNotifications(count: rollup.unreadTotal))
        }

        if hasBackgroundedFloatingWork {
            parts.append("backgrounded floating panel running")
        }

        if session.notificationsMuted {
            parts.append(
                String(
                    localized: "notifications muted",
                    comment: "Accessibility label fragment for a sidebar workspace whose macOS notifications are muted."
                ))
        }

        return parts.joined(separator: ", ")
    }

    static func workspaceIdentityAccessibilityLabel(
        session: TerminalSession,
        rollup: SessionAgentRollup,
        bundle: Bundle = .main,
        locale: Locale = .current
    ) -> String {
        SidebarVisibleRows.workspaceAccessibilityLabel(
            title: session.displayTitle(bundle: bundle, locale: locale),
            agentKind: rollup.winningAgentKind,
            state: rollup.state,
            bundle: bundle,
            locale: locale
        )
    }

    private func locationAccessibilityLabel(location: SidebarSessionLocation) -> String {
        let label = location.accessibilityLabel
        guard let duplicateDisambiguation else {
            return label
        }

        return "\(label), \(duplicateDisambiguation.accessibilitySuffix)"
    }

    private var rowAccessibilityValue: String {
        let position = "Workspace \(indexInGroup + 1) of \(sessionCountInGroup)"
        guard let pinnedOriginGroupName else {
            return position
        }
        // `.help()` origin tooltip is pointer-only; VoiceOver hears the origin
        // here so a pinned tile still answers "which project is this?".
        return position + ", "
            + String(
                localized: "Pinned, from \(pinnedOriginGroupName)",
                comment: "VoiceOver value fragment on a pinned sidebar workspace naming its origin group."
            )
    }

    private func paneJumpActionLabel(_ item: PanePeekItem) -> String {
        var parts = ["Jump to pane \(item.paneNumber)", item.title, item.agentShortName, item.state.label]
        if let remoteHost = item.remoteHost {
            parts.append(
                String(
                    localized: "remote on \(remoteHost)",
                    comment: "VoiceOver action fragment naming the remote host for a pane."
                )
            )
        }
        if item.unread > 0 {
            parts.append(LocalizedPluralStrings.sidebarNotifications(count: item.unread))
        }
        if item.isActive {
            parts.append("active pane")
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Equatable render key

extension SidebarSessionTile: Equatable {
    /// Everything the row renders, as one comparable value, so `.equatable()`
    /// at the call sites (`SidebarGroupView`, `SidebarPinnedSectionView`) can
    /// skip re-running `body` — including its expensive
    /// `.accessibilityElement(children: .combine)` node with its 7-11
    /// accessibility actions — for rows whose rendered inputs did not change.
    ///
    /// `TerminalPane`/`TerminalSession` `==` deliberately exclude runtime-only
    /// fields (`shellActivity` et al) whose chrome renders through
    /// projections instead — see the "revisit" note in `TerminalPane.=='s`
    /// doc comment. This key is that revisit: every pane read goes through
    /// `effectiveChromeState` (which folds `shellActivity`), NEVER raw
    /// pane/session equality.
    ///
    /// Full non-closure stored-property enumeration of `SidebarSessionTile`
    /// (read 2026-07-17), so a reviewer can mechanically diff key fields
    /// against stored properties:
    ///   session, match, tint, isActive, displayMode, isKeyboardFocused,
    ///   showsSearchFocusCue,
    ///   jumpIndex, hasBackgroundedFloatingWork, isPromotedInsertion,
    ///   isPromotionPulseActive, isFiltering, duplicateDisambiguation,
    ///   indexInGroup, sessionCountInGroup, ownerGroupIndex,
    ///   previousNeighborGroup, nextNeighborGroup, otherGroups,
    ///   verticalPadding, onSelect (closure), onNewSessionHere (closure),
    ///   onAcknowledge (closure), onMoveWithinGroup (closure),
    ///   onMoveToGroup (closure), onClose (closure), onClear (closure),
    ///   onRename (closure), canMakeWorkspaceManaged,
    ///   onMakeWorkspaceManaged (closure), onToggleNotificationsMute
    ///   (closure), isPinned, onTogglePin (closure), pinnedOriginGroupName,
    ///   onDragStarted (closure), focusedRowTarget, isKeyboardNavigatingValue,
    ///   isKeyboardNavigating (@Binding), isHovered (@State), promotionPulseIsBright (@State),
    ///   promotionPulseTask (@State), isPeekVisible (@State), peekTask
    ///   (@State), tileFrame (@State), peekModel (@Environment), contrast
    ///   (@Environment), reduceMotion (@Environment), appSettingsStore
    ///   (@Environment), isCommandKeyHeld (@Environment).
    ///
    /// Excluded, not missed:
    /// - Every closure above — never comparable, excluded per the Task 3
    ///   invariant. Their identity has no bearing on what the row displays.
    /// - `focusedRowTarget` (`FocusState<SidebarVisibleRowTarget?>.Binding`)
    ///   — a `Binding` wraps get/set closures, so it isn't comparable, and
    ///   its only use here is wiring `.focused(_:equals:)`. Its RENDERED
    ///   effect is already fully captured: the caller precomputes
    ///   `isKeyboardFocused` from this same binding's current value at
    ///   construction time (`focusedRowTarget.wrappedValue == .session(id)`),
    ///   so `isKeyboardFocused` alone determines everything this binding's
    ///   value would otherwise change about the row.
    /// - `isKeyboardNavigating` (`@Binding<Bool>`) — write-only plumbing for
    ///   the tap and hover handlers to clear keyboard-modality state on a
    ///   pointer signal. Its RENDERED effect is fully captured by
    ///   `isKeyboardNavigatingValue` below, an immutable snapshot taken at
    ///   construction time; comparing the binding itself would be comparing
    ///   get/set closures (not comparable), and reading through its live
    ///   getter from `==` would see the CURRENT value on both the old and
    ///   new instance being compared (they share the same binding), making
    ///   the read permanently self-equal and inert.
    /// - `isHovered`, `promotionPulseIsBright`, `promotionPulseTask`,
    ///   `isPeekVisible`, `peekTask`, `tileFrame` — `@State`, not a
    ///   constructor input. SwiftUI persists this storage across
    ///   reconstructions of the SAME row identity and updates it through the
    ///   ordinary `@State` path, independent of this Equatable gate.
    /// - `peekModel`, `contrast`, `reduceMotion`, `appSettingsStore`,
    ///   `isCommandKeyHeld` — `@Environment`, ambient/Observation-tracked
    ///   reads, not a constructor input. A change to any of these invalidates
    ///   this row's body directly and is not gated by `.equatable()`.
    ///
    /// `isKeyboardNavigatingValue` is included as a plain field for the same
    /// reason `isKeyboardFocused` is: `interactiveTile` gates
    /// `.awFocusRing` on keyboard focus/modality or `showsSearchFocusCue`, so
    /// the ring's rendered state has to match what the key compares — an
    /// equal-comparing row that skipped re-render could otherwise show a
    /// stale ring after a keyboard→pointer modality switch. Both callers
    /// pass their live value at construction time (mirroring how
    /// `isKeyboardFocused` is already precomputed from `focusedRowTarget`),
    /// so this is a snapshot, not a binding read.
    ///
    /// `isPinned`/`pinnedOriginGroupName` are two more fields beyond the
    /// original brief: `isPinned` changes `pinMenuTitle` (context-menu title
    /// + its named accessibility action), and `pinnedOriginGroupName` changes
    /// `rowAccessibilityValue`'s spoken origin-group fragment — both are
    /// call-site-varying (`SidebarPinnedSectionView` passes `isPinned: true`
    /// and a real origin name; `SidebarGroupView` passes `isPinned: false`
    /// and `nil`).
    private struct RenderKey: Equatable {
        let sessionID: TerminalSession.ID
        let title: String
        // Folds the active pane's resolved remote host / cwd (and the
        // accessibility label) through the SAME computed property `body`
        // reads (`session.sidebarLocation`) — never raw pane fields.
        let location: SidebarSessionLocation
        let notificationsMuted: Bool
        // Session-level cwd, NOT folded into `paneChrome`'s per-pane
        // `workingDirectory` above: row closures (e.g. "New Workspace Here")
        // capture the session VALUE, so a background pane's cwd report
        // updating `session.workingDirectory` without touching the active
        // pane's keyed cwd would otherwise leave an equal-comparing row
        // holding a closure with a stale directory. Keying it here forces the
        // row (and its captured closures) to rebuild.
        let sessionWorkingDirectory: String
        // Which pane is active isn't otherwise implied by `paneChrome` below
        // (that array carries no per-pane "is active" flag), so this stays a
        // dedicated field — it drives `location` above and which pane-jump
        // action reads "active pane" in `paneJumpActionLabel`.
        let activePaneID: TerminalPane.ID
        let paneChrome: [PaneChromeKey]
        let match: SessionMatch?
        // Keyed on the accent alone, not the whole `ProjectTint` — `hue` and
        // `borderHue` are pure functions of `accent` (see `ProjectTint.init`),
        // and `ProjectTint` itself isn't `Equatable`. The same accent always
        // renders identically, so this is a lossless, cheaper projection.
        let tintAccent: AwTintAccent
        let isActive: Bool
        let displayMode: SidebarWidthMode
        let isKeyboardFocused: Bool
        let showsSearchFocusCue: Bool
        let jumpIndex: Int?
        let hasBackgroundedFloatingWork: Bool
        let isPromotedInsertion: Bool
        let isPromotionPulseActive: Bool
        let isFiltering: Bool
        let duplicateDisambiguation: SidebarDuplicateDisambiguation?
        let indexInGroup: Int
        let sessionCountInGroup: Int
        let ownerGroupIndex: Int
        let previousNeighborGroup: NeighborKey?
        let nextNeighborGroup: NeighborKey?
        let otherGroups: [NeighborKey]
        let verticalPadding: CGFloat
        let canMakeWorkspaceManaged: Bool
        let isPinned: Bool
        let pinnedOriginGroupName: String?
        let isKeyboardNavigatingValue: Bool
    }

    /// One pane's rendered contribution. `id` + array order together let the
    /// key detect a pane reorder even when every pane's own content is
    /// unchanged. `agentKind` is included because `SessionAgentRollup.from`
    /// (which drives the tile's `AgentTile` icon/badge and `tileBorder`'s
    /// `.needs` check) picks its winning pane purely from
    /// `(chromeState.priority, input order)` — `chromeState` + array order
    /// alone determine WHICH pane wins, but `agentKind` is needed to know
    /// what icon that winner contributes.
    private struct PaneChromeKey: Equatable {
        let id: TerminalPane.ID
        let chromeState: AgentState
        let agentKind: AgentKind
        let unread: Int
        let attentionReason: AttentionReason?
        let progressReport: TerminalProgressReport?
        let title: String
        // `remotePresentationHost`, not the raw ephemeral `remoteHost` field
        // — the former is what `sidebarLocation` and the per-pane jump-action
        // label actually render (a durable SSH plan can win over a stale/nil
        // observed `remoteHost`).
        let remoteHost: String?
        let workingDirectory: String
    }

    private struct NeighborKey: Equatable {
        let id: SessionGroup.ID
        let name: String
    }

    // `nonisolated` because `Equatable.==` is not main-actor (same rationale
    // as `AgentTile.==`, above): the compared fields are all value-type,
    // effectively-Sendable data — `SidebarSessionTile` gets its actor
    // isolation from being a `View`, not from any of the data it holds.
    nonisolated private var renderKey: RenderKey {
        RenderKey(
            sessionID: session.id,
            title: session.title,
            location: session.sidebarLocation,
            notificationsMuted: session.notificationsMuted,
            sessionWorkingDirectory: session.workingDirectory,
            activePaneID: session.activePaneID,
            paneChrome: session.panes.map { pane in
                PaneChromeKey(
                    id: pane.id,
                    chromeState: pane.effectiveChromeState,
                    agentKind: pane.agentKind,
                    unread: pane.unreadNotificationCount,
                    attentionReason: pane.attentionReason,
                    progressReport: pane.progressReport,
                    title: pane.title,
                    remoteHost: pane.remotePresentationHost,
                    workingDirectory: pane.workingDirectory
                )
            },
            match: match,
            tintAccent: tint.accent,
            isActive: isActive,
            displayMode: displayMode,
            isKeyboardFocused: isKeyboardFocused,
            showsSearchFocusCue: showsSearchFocusCue,
            jumpIndex: jumpIndex,
            hasBackgroundedFloatingWork: hasBackgroundedFloatingWork,
            isPromotedInsertion: isPromotedInsertion,
            isPromotionPulseActive: isPromotionPulseActive,
            isFiltering: isFiltering,
            duplicateDisambiguation: duplicateDisambiguation,
            indexInGroup: indexInGroup,
            sessionCountInGroup: sessionCountInGroup,
            ownerGroupIndex: ownerGroupIndex,
            previousNeighborGroup: previousNeighborGroup.map { NeighborKey(id: $0.id, name: $0.name) },
            nextNeighborGroup: nextNeighborGroup.map { NeighborKey(id: $0.id, name: $0.name) },
            otherGroups: otherGroups.map { NeighborKey(id: $0.id, name: $0.name) },
            verticalPadding: verticalPadding,
            canMakeWorkspaceManaged: canMakeWorkspaceManaged,
            isPinned: isPinned,
            pinnedOriginGroupName: pinnedOriginGroupName,
            // The immutable snapshot, not the live `@Binding` — the OLD and
            // NEW tile instances compared by `==` share the same binding, so
            // reading through its getter here would see the CURRENT value on
            // both sides regardless of which value was live when each
            // instance was built, making the comparison permanently equal.
            // `isKeyboardNavigatingValue` is captured once at construction,
            // so it differs across old/new instances exactly when the
            // caller's value actually changed. Writes still go through the
            // binding (see its declaration above) — this key never touches it.
            isKeyboardNavigatingValue: isKeyboardNavigatingValue
        )
    }

    nonisolated static func == (lhs: SidebarSessionTile, rhs: SidebarSessionTile) -> Bool {
        lhs.renderKey == rhs.renderKey
    }
}

struct SidebarCloseButton: View {
    // The close affordance stays at full strength regardless of hover so it's
    // discoverable to keyboard and VoiceOver users, not just on pointer hover
    // (INT-8). Do not reintroduce a hover-gated opacity here.
    let onClose: () -> Void

    var body: some View {
        Button(role: .destructive) {
            onClose()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.aw.text)
        .padding(.trailing, 10)
        .accessibilityLabel("Close Workspace")
        .help("Close Workspace")
    }
}

struct NotificationBadge: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .foregroundStyle(Color.aw.status.onLoud)
            .background(Color.aw.status.needs, in: Capsule())
            .accessibilityHidden(true)
    }
}
