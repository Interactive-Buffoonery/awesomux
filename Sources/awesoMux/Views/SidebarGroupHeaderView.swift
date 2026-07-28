import AwesoMuxConfig
import AwesoMuxCore
import DesignSystem
import SwiftUI

private struct SidebarGroupHeaderHoverOverrideKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

extension EnvironmentValues {
    /// Overrides pointer hover for deterministic hosted-view rendering tests.
    /// Production leaves this nil and continues to use live `onHover` state.
    var sidebarGroupHeaderHoverOverride: Bool? {
        get { self[SidebarGroupHeaderHoverOverrideKey.self] }
        set { self[SidebarGroupHeaderHoverOverrideKey.self] = newValue }
    }
}

/// Gate for the group header's close-group X (INT-739) — a hover reveal over
/// the count badge, except in an expanded empty group, where it rests visible.
///
/// Beyond that, the X carries the same guards as the context menu's
/// "Close Group" (see `groupContextMenuContent` for the rationale):
/// suppressed while filtering (the header reflects only the matched
/// subset, so closing would destroy hidden workspaces), for unresolved
/// or stale rows (no resolved group index — an ID-keyed mutation could
/// hit a different group than the one shown), and for the sole empty
/// group, where the store refuses to remove the last group so the X
/// would be a dead control — the same clause the context menu's "Close
/// Group" disables on. Empty groups among others DO get the X (INT-770):
/// closing routes through `closeWorkspaceGroup`, which skips the confirm
/// dialog when there is no remote impact but still confirms loss of an SSH
/// creation default. This X is the sole pointer path for every group: it rests
/// visible (no hover needed) in an expanded EMPTY group, and is a hover reveal
/// everywhere else. `NewWorkspaceInGroupRow` used to carry a second persistent
/// X for empty groups precisely because this one was hover-only; now that the
/// empty case rests visible here, that duplicate is gone — two pointer paths to
/// the same destructive action invited the wrong one being clicked, and one of
/// them sat in a row whose entire purpose is creation.
///
/// `isCollapsed` (the group's own rows hidden — distinct from the
/// rail-collapsed `displayMode`, which suppresses the X entirely) keeps the
/// count badge, because a collapsed body makes the count the only signal of
/// what is inside.
enum SidebarGroupClosePolicy {
    static let actionLabel = String(
        localized: "Close Group",
        comment: "Label and help text for controls that close a workspace group."
    )

    /// This decides both visibility and hit-testing — `SidebarGroupHeaderRow`
    /// drives them from this one value, because an X that is drawn but ignores
    /// a click is its own bug. A resting X can therefore be clicked the instant
    /// a rebuild slides it under a stationary pointer; that is accepted rather
    /// than guarded, because `removeGroup` registers undo and gating on hover
    /// does not prevent it (the arriving header gets a real hover-enter).
    ///
    /// - Parameters:
    ///   - isHeaderHovered: pointer is over the header row. Reveals the X
    ///     everywhere except the expanded empty group, where it already rests
    ///     visible.
    ///   - displayMode: sidebar width mode; the collapsed rail renders no
    ///     count badge, so there is no slot to morph.
    ///   - isFiltering: the header reflects only the matched subset while
    ///     filtering, so a whole-group close could destroy hidden rows.
    ///   - hasResolvedGroupIndex: false for unresolved/stale rows, where an
    ///     ID-keyed mutation could hit a different group than shown.
    ///   - isGroupEmpty: the model's `group.sessions` emptiness (not the
    ///     filtered projection).
    ///   - totalGroupCount: total groups in the store; feeds the
    ///     sole-empty-group dead-control clause.
    ///   - isGroupCollapsed: the group's own rows are hidden. An expanded
    ///     empty group shows its emptiness directly, so the count badge is
    ///     redundant there and the X rests in that slot instead of waiting
    ///     for hover.
    ///   - isDragActive: any sidebar drag is in flight. Suppresses the resting
    ///     X — a drag is aiming at drop targets, and a destructive control
    ///     sitting in the flight path is the wrong thing to leave lit. The
    ///     hover half needs no term here: the row zeroes its hover flag when a
    ///     drag starts (tracking-area exits stop being delivered mid-drag).
    static func showsCloseButton(
        isHeaderHovered: Bool,
        displayMode: SidebarWidthMode,
        isFiltering: Bool,
        hasResolvedGroupIndex: Bool,
        isGroupEmpty: Bool,
        totalGroupCount: Int,
        isGroupCollapsed: Bool,
        isDragActive: Bool
    ) -> Bool {
        // An expanded empty group has a visibly empty body, so "0" tells the
        // user nothing they cannot already see, and the X is the only thing
        // that slot can usefully hold. Collapsed, the body is hidden and the
        // count IS the only signal of what is in there, so it keeps the slot
        // and the X stays a hover reveal. A live drag suppresses the resting
        // half outright — the empty group's body is itself a drop target, and
        // the pointer is on its way there.
        let restsVisible = isGroupEmpty && !isGroupCollapsed && !isDragActive
        return (isHeaderHovered || restsVisible)
            && displayMode != .collapsed
            && !isFiltering
            && hasResolvedGroupIndex
            && !closeIsDeadControl(isGroupEmpty: isGroupEmpty, totalGroupCount: totalGroupCount)
    }

    /// True when closing the group would be a no-op: `removeGroup` refuses
    /// the last group, so the sole empty group's close is a dead control.
    /// Single source of truth for the hover X, the context menu's "Close
    /// Group" `.disabled`, and the accessibility action's suppression —
    /// keep all three routed here so they can't drift apart.
    static func closeIsDeadControl(isGroupEmpty: Bool, totalGroupCount: Int) -> Bool {
        isGroupEmpty && totalGroupCount <= 1
    }
}

/// The group header row, extracted from `SidebarGroupView` so that its hover
/// state (`isHeaderHovered`, which drives the count-badge → close-X morph)
/// invalidates ONLY this subview. As `@State` on the parent it re-evaluated the
/// whole group body — including every `SidebarSessionTile` in the list — on each
/// pointer enter/exit (the known sidebar re-render-storm shape).
struct SidebarGroupHeaderRow: View {
    let group: SessionGroup
    let entries: [SidebarSessionEntry]
    let density: SidebarDensity
    let tint: ProjectTint
    let isCollapsed: Bool
    let isFiltering: Bool
    let displayMode: SidebarWidthMode
    let selectedSessionID: TerminalSession.ID?
    let currentGroupIndex: Int?
    let totalGroupCount: Int
    /// `activeDragKind != nil` from the parent — any in-flight drag. Drags
    /// suppress tracking-area exits, so hover must be reset when one starts.
    let isDragActive: Bool
    let onToggle: () -> Void
    let onNewSessionInGroup: () -> Void
    let onConnectViaSSH: (SessionGroup) -> Void
    let onNewGroup: () -> Void
    let onRenameGroup: () -> Void
    let onSetGroupColor: (WorkspaceGroupColor?) -> Void
    let onCloseGroup: () -> Void
    let onMoveGroup: (Int, Int) -> Void
    let onGroupDragStarted: (SessionGroup.ID) -> UUID
    let focusedRowTarget: FocusState<SidebarVisibleRowTarget?>.Binding
    @Binding var isKeyboardNavigating: Bool

    @State private var isHeaderHovered = false
    @State private var isPeekVisible = false
    @State private var peekTask: Task<Void, Never>?
    /// This header's box in the sidebar pane's `.global` space — handed to
    /// `SidebarPeekModel` so `ContentView` can draw the peek card aligned
    /// with the header, above the split. Mirrors `SidebarSessionTile.tileFrame`.
    @State private var headerFrame: CGRect = .zero
    @Environment(SidebarPeekModel.self) private var peekModel
    @Environment(AppSettingsStore.self) private var appSettingsStore
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.sidebarGroupHeaderHoverOverride) private var headerHoverOverride
    // Mirror the count badge's scaling: it renders with `.awFont(.Mono.meta)`,
    // whose point size is `@ScaledMetric(relativeTo: .subheadline)` off
    // `spec(.meta).baseSize` times the user `\.awTextScale` factor. Reproducing
    // both inputs here lets the close-X glyph and hit frame track the count text
    // instead of staying frozen at 9pt while a scaled count grows past it
    // (INT-237). At 100% both factors are 1.0, so the X renders byte-identically.
    @ScaledMetric(relativeTo: .subheadline)
    private var metaFontSize: CGFloat = AwFont.spec(AwFont.Mono.meta).baseSize
    @Environment(\.awTextScale) private var textScale

    private var sessions: [TerminalSession] {
        entries.map(\.session)
    }

    private var executionPresentation: SessionGroupExecutionPresentation {
        SessionGroupExecutionPresentation(
            summary: executionSummary
        )
    }

    private var executionSummary: SessionGroupExecutionSummary {
        SessionGroupExecutionSummary(group: group)
    }

    /// Only the collapsed rail's header shows the group roster — the
    /// expanded header already lists every workspace inline, and hovering
    /// an individual tile keeps showing the existing single-session peek
    /// (mutually exclusive by construction: this trigger and the tile's
    /// trigger call different `SidebarPeekModel` methods).
    private var canPeek: Bool {
        displayMode == .collapsed
    }

    private func updatePeekVisibility() {
        guard canPeek,
            isHeaderHovered || (focusedRowTarget.wrappedValue == .group(group.id) && isKeyboardNavigating)
        else {
            cancelPeek()
            return
        }
        guard !isPeekVisible else { return }

        peekTask?.cancel()
        peekTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            isPeekVisible = true
        }
    }

    private func cancelPeek() {
        peekTask?.cancel()
        peekTask = nil
        guard isPeekVisible else { return }
        isPeekVisible = false
    }

    /// The count text's scale relative to its 100% size, so the close-X can
    /// multiply its base 9pt glyph / 20pt frame and stay proportional.
    private var textScaleFactor: CGFloat {
        (metaFontSize / AwFont.spec(AwFont.Mono.meta).baseSize) * CGFloat(AwTextScale.clamp(textScale))
    }

    /// Live pointer presence over the header, or the test override standing in
    /// for it. Feeds the close policy's hover term; an expanded empty group
    /// rests its X without this, and the peek lifecycle owns the resets.
    private var isPointerOverHeader: Bool {
        headerHoverOverride ?? isHeaderHovered
    }

    /// The close-group X takes the count badge's slot in the expanded header —
    /// resting there for an empty group, on hover otherwise; the collapsed
    /// rail renders no badge, so no X (INT-739). Gate logic lives in
    /// `SidebarGroupClosePolicy` so its truth table is unit-testable.
    private var showsGroupCloseButton: Bool {
        SidebarGroupClosePolicy.showsCloseButton(
            isHeaderHovered: isPointerOverHeader,
            displayMode: displayMode,
            isFiltering: isFiltering,
            hasResolvedGroupIndex: currentGroupIndex != nil,
            // Reads the model's `group.sessions` (like the context menu's
            // disabled check), not the projected `entries` the count badge
            // renders. The projection also floats pinned sessions out of their
            // group with no filter active (`SidebarPinnedProjection.apply`), so
            // `entries` can be empty for a group that still holds workspaces —
            // exactly the direction that would rest a close X over a group the
            // store then refuses to remove.
            isGroupEmpty: group.sessions.isEmpty,
            totalGroupCount: totalGroupCount,
            isGroupCollapsed: isCollapsed,
            isDragActive: isDragActive
        )
    }

    var body: some View {
        let isHighContrast = contrast == .increased
        let groupTintMarkerSize: CGFloat = isHighContrast ? 8 : 6

        // Split at the peek-lifecycle modifiers (`withPeekLifecycle`) so the
        // type-checker sees two expressions instead of one — the combined
        // chain (gestures + focus + drag + peek onChange×7 + accessibility)
        // times out, the same failure mode `groupContextMenuContent`'s own
        // extraction comment describes for the menu content.
        let chrome = groupHeader(
            isHighContrast: isHighContrast,
            groupTintMarkerSize: groupTintMarkerSize
        )
        .padding(.horizontal, displayMode == .collapsed ? 0 : 4)
        .padding(.bottom, density.groupHeaderBottomPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        // `.simultaneousGesture(TapGesture)` instead of `.onTapGesture`
        // — the latter is gesture-exclusive on macOS and blocks
        // `.onDrag` from activating. `.simultaneousGesture` composes
        // with the drag so both can fire (tap on quick click, drag
        // on hold + motion).
        .simultaneousGesture(
            TapGesture().onEnded {
                isKeyboardNavigating = false
                onToggle()
            }
        )
        // Deliberately NOT the session row's vacate-on-tap treatment
        // (INT-652): a header click toggles collapse without changing the
        // selection, so no surface mounts and nothing would reclaim a
        // vacated responder. Parking focus on the header (click-to-focus)
        // keeps sidebar arrow-key navigation alive after a collapse, and
        // also retargets focus off any row the collapse just hid.
        .focusable()
        .focused(focusedRowTarget, equals: .group(group.id))
        // Suppress the macOS system focus ring; the accent `awFocusRing`
        // below is our keyboard-only focus indicator (see session row).
        .focusEffectDisabled()
        .awFocusRing(
            focusedRowTarget.wrappedValue == .group(group.id) && isKeyboardNavigating,
            cornerRadius: 6
        )
        .onDrag {
            let dragID = onGroupDragStarted(group.id)
            let provider = NSItemProvider()
            registerSidebarDragPayload(
                WorkspaceGroupDragItem(groupID: group.id, dragID: dragID),
                on: provider
            )
            return provider
        } preview: {
            SidebarGroupDragPreview(
                name: group.name,
                count: sessions.count,
                tint: tint.hue
            )
        }
        // Sibling overlay, not a child of the header HStack — mirrors the
        // session tile's close button (SidebarSessionTile) so the Button's
        // click never reaches the header's simultaneous collapse-toggle
        // TapGesture. Order is load-bearing: this must stay AFTER
        // .simultaneousGesture and .onDrag, or the parent tap fires too.
        .overlay(alignment: .trailing) { groupCloseButton }
        .background {
            if canPeek {
                Color.clear
                    .onGeometryChange(for: CGRect.self) { proxy in
                        proxy.frame(in: .global)
                    } action: {
                        headerFrame = $0
                    }
            }
        }
        // .onHover must sit ABOVE the overlay (mirrors the session tile's
        // order), so the X counts as part of the hovered region. Attached
        // below it, the hover-gated hittable X occludes the header, which
        // reads as a pointer EXIT → gate flips → X unhittable → re-enter →
        // … an X/count oscillation as the pointer nears the badge.
        .onHover { hovering in
            isHeaderHovered = hovering
            // Moving the pointer over the header is a pointer-modality
            // signal, so hide the keyboard focus ring.
            if hovering {
                isKeyboardNavigating = false
            }
            updatePeekVisibility()
        }

        return withPeekLifecycle(chrome)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            // Default activation for VoiceOver (VO+space). Refactoring
            // off `Button` to free `.onDrag` removed the built-in
            // button activation — restoring it explicitly so the
            // announced `.isButton` trait actually does something.
            .accessibilityAction { onToggle() }
            .accessibilityLabel(
                {
                    // Include color tint in the label so VoiceOver users hear the
                    // currently-assigned color — the visual 6×6 dot is otherwise
                    // the only signal that a user-chosen tint actually applied.
                    let colorSuffix = group.color.map { ", \($0.displayName) tint" } ?? ""
                    let location = executionPresentation.accessibilityText
                    if sessions.isEmpty {
                        return "\(group.name), empty workspace group, \(location)\(colorSuffix)"
                    }
                    return
                        "\(group.name), \(LocalizedPluralStrings.sidebarGroupWorkspaces(count: sessions.count)), \(location)\(colorSuffix)"
                }()
            )
            .accessibilityValue(groupAccessibilityValue)
            .accessibilityAddTraits(.isHeader)
            .accessibilityAddTraits(
                sessions.contains(where: { $0.id == selectedSessionID }) ? [.isSelected] : []
            )
            .contextMenu { groupContextMenuContent }
            .accessibilityActions { groupAccessibilityActionsContent }
    }

    /// The group-roster peek's full hover/keyboard/drag/filter lifecycle,
    /// extracted out of `body`'s modifier chain for the same type-checking
    /// reason `groupContextMenuContent` was extracted (see its comment) —
    /// this many `.onChange` handlers plus everything else in `body` is too
    /// much for one expression.
    @ViewBuilder
    private func withPeekLifecycle(_ content: some View) -> some View {
        content
            // mouseExited isn't delivered when the header is torn out from
            // under a stationary pointer (filter removes the group, structural
            // rebuild) — same reset the session tile carries. Without it a
            // stale-true flag both reveals AND arms the X on reappear with no
            // live hover. The resting X (expanded empty group) is revealed
            // regardless, but this reset still governs whether it can be
            // clicked, which is the half that destroys a group.
            .onDisappear {
                isHeaderHovered = false
                cancelPeek()
                peekModel.hideGroup(for: group.id)
            }
            // A drag suppresses tracking-area exit events, so the origin
            // header's hover flag would strand true (and the hover X strand
            // visible and armed) after the group lands elsewhere. (Was a
            // parent-level `.onChange(of: activeDragKind)`; moved here with the
            // state.) The resting X is covered by the policy's own
            // `isDragActive` term instead — nothing to reset, since it never
            // read hover in the first place.
            .onChange(of: isDragActive) { _, active in
                if active {
                    isHeaderHovered = false
                    cancelPeek()
                }
            }
            // Arming the X requires a fresh hover: without this, clearing the
            // filter by keyboard while the pointer rests on a header widens the
            // gate under a stationary pointer and the X becomes clickable with
            // no hover gesture (stale-state-plus-widened-gate, INT-562 family).
            // For an expanded empty group the X also becomes VISIBLE at that
            // moment — that part is intended; being immediately clickable is
            // not. (Was a parent-level `.onChange(of: isFiltering)`.)
            .onChange(of: isFiltering) { _, _ in
                isHeaderHovered = false
                cancelPeek()
            }
            .onChange(of: isPeekVisible) { _, visible in
                if visible {
                    peekModel.showGroup(
                        group: group,
                        tint: tint,
                        sessions: sessions,
                        activeSessionID: selectedSessionID,
                        frame: headerFrame,
                        position: appSettingsStore.appearance.value.sidebarPosition
                    )
                } else if canPeek {
                    // Always hittable (every row jumps), so always request the
                    // graced hide — never the immediate one — matching the
                    // multi-pane tile's card, not the single-pane summary path.
                    peekModel.requestHideGroup(for: group.id)
                } else {
                    // The rail itself stopped being collapsed — there's no gap
                    // left for the pointer to be reaching across, so the grace
                    // (which exists to survive that gap) doesn't apply here. An
                    // immediate hide prevents the card from stranding open if the
                    // pointer happens to be resting on it when displayMode changes.
                    peekModel.hideGroup(for: group.id)
                }
            }
            .onChange(of: headerFrame) { _, frame in
                peekModel.updateGroupFrame(
                    for: group.id,
                    frame: frame,
                    position: appSettingsStore.appearance.value.sidebarPosition
                )
            }
            // Keyed on `peekRefreshKey` (not just `entries`' plain equality) so
            // a per-session state change entries' `==` excludes (e.g. a shell
            // idle↔busy flip) still refreshes a live card — same reasoning as
            // the single-session tile's `peekRefreshKey` onChange. This array
            // is a strict superset of what an `entries`-keyed onChange would
            // catch: any add/remove/reorder also changes this array's length
            // or order.
            .onChange(of: sessions.map(\.peekRefreshKey)) { _, _ in
                peekModel.refreshGroup(
                    group: group,
                    tint: tint,
                    sessions: sessions,
                    activeSessionID: selectedSessionID
                )
            }
            .onChange(of: executionSummary) { _, _ in
                peekModel.refreshGroup(
                    group: group,
                    tint: tint,
                    sessions: sessions,
                    activeSessionID: selectedSessionID
                )
            }
            // The roster's active-row highlight is derived from
            // `selectedSessionID`, which can change without touching this
            // group's own `entries` (e.g. selecting a session in a different
            // group) — without this the highlight goes stale on a live card.
            .onChange(of: selectedSessionID) { _, _ in
                peekModel.refreshGroup(
                    group: group,
                    tint: tint,
                    sessions: sessions,
                    activeSessionID: selectedSessionID
                )
            }
            .onChange(of: displayMode) { _, _ in
                // Re-evaluate on a ⌘\ toggle even when the pointer never moves
                // — expanding the rail must dismiss a showing group peek
                // (`canPeek` gates it off), matching the tile's own
                // displayMode re-check.
                updatePeekVisibility()
            }
            .onChange(of: focusedRowTarget.wrappedValue) { _, _ in
                updatePeekVisibility()
            }
    }

    @ViewBuilder
    private func groupHeader(
        isHighContrast: Bool,
        groupTintMarkerSize: CGFloat
    ) -> some View {
        if displayMode == .collapsed {
            VStack(spacing: 5) {
                RoundedRectangle(cornerRadius: isHighContrast ? 2 : 1.5)
                    .fill(tint.hue)
                    .frame(width: 14, height: isHighContrast ? 3.5 : 2.5)
                    .overlay {
                        if isHighContrast {
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(Color.aw.dividerRestHC, lineWidth: 0.75)
                        }
                    }
                    .awGlow(color: tint.hue.opacity(0.7), radius: 4)

                if isCollapsed {
                    // The group's own rows (and their per-tile badges) are hidden
                    // while collapsed, so roll the hidden attention states up onto
                    // the rail header — otherwise a needing workspace is invisible
                    // until the user guesses which group to expand (INT-261).
                    if let state = collapsedGroupAttention.primaryState {
                        RailGroupAttentionBadge(state: state)
                    }

                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        // Functional expand cue on mantle — needs 1.4.11 3:1.
                        // textFaint is ~2.14:1 Latte; railText clears with room.
                        .foregroundStyle(Color.aw.railText)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: 40)
            .frame(minHeight: 26)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        } else {
            HStack(spacing: 8) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                    .frame(width: 8)
                    // Functional collapse cue on mantle — text3 is ~2.63:1 Latte.
                    .foregroundStyle(Color.aw.railText)

                RoundedRectangle(cornerRadius: isHighContrast ? 2 : 1)
                    .fill(tint.hue)
                    .frame(width: groupTintMarkerSize, height: groupTintMarkerSize)
                    .overlay {
                        if isHighContrast {
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(Color.aw.dividerRestHC, lineWidth: 0.75)
                        }
                    }
                    .awGlow(color: tint.hue.opacity(0.7), radius: 4)

                Text(group.name)
                    .awFont(AwFont.Mono.kicker)
                    .tracking(1)
                    .textCase(.uppercase)
                    // railText clears AA on mantle; stock text2 is 4.06:1 Latte.
                    .foregroundStyle(Color.aw.railText)
                    .lineLimit(1)

                if let location = executionPresentation.visibleText {
                    Text(location)
                        .awFont(AwFont.Mono.meta)
                        .foregroundStyle(Color.aw.railText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 4)

                if isCollapsed {
                    groupCollapsedStatusDot
                }

                Text("\(sessions.count)")
                    .awFont(AwFont.Mono.meta)
                    // Workspace count is meaningful text on mantle; textFaint is
                    // ~2.14:1 Latte. Hierarchy stays via font size, not faint color.
                    .foregroundStyle(Color.aw.railText)
                    .monospacedDigit()
                    // Hidden (not removed) while the close X overlays this slot, so
                    // the header's layout never shifts on hover.
                    .opacity(showsGroupCloseButton ? 0 : 1)
            }
        }
    }

    // ponytail: extracted out of `body`'s modifier chain — the compiler
    // times out type-checking the whole chain as one expression once it grows
    // past ~a dozen modifiers; splitting the menu content into its own
    // `@ViewBuilder` var gives it a separate, fast-to-check expression.
    @ViewBuilder
    private var groupContextMenuContent: some View {
        Button("New Workspace in Group") {
            onNewSessionInGroup()
        }

        Button("Connect via SSH…") {
            onConnectViaSSH(group)
        }

        Button("New Workspace Group…") {
            onNewGroup()
        }

        Button("Rename Workspace Group…") {
            onRenameGroup()
        }

        Menu("Color…") {
            Button {
                setGroupColor(nil)
            } label: {
                colorMenuLabel("Default", swatch: nil, isSelected: group.color == nil)
            }
            .accessibilityAddTraits(group.color == nil ? [.isSelected] : [])

            if let legacyColor = currentLegacyColor {
                Button {
                } label: {
                    colorMenuLabel(
                        legacyColor.displayName,
                        swatch: ProjectTint.color(for: legacyColor),
                        isSelected: true
                    )
                }
                .disabled(true)
                .accessibilityAddTraits(.isSelected)
            }

            ForEach(WorkspaceGroupColor.pickerCases, id: \.self) { color in
                Button {
                    setGroupColor(color)
                } label: {
                    colorMenuLabel(
                        color.displayName,
                        swatch: ProjectTint.color(for: color),
                        isSelected: group.color == color
                    )
                }
                .accessibilityAddTraits(group.color == color ? [.isSelected] : [])
            }
        }
        // Announce the currently-selected color on the submenu trigger
        // so VoiceOver users hear it without opening the submenu.
        .accessibilityValue(group.color?.displayName ?? "Default")

        // macOS HIG: show both reorder actions when reordering is
        // possible, disable the inapplicable one at the edges. Hiding
        // would make the menu shape jitter across rows and break
        // muscle memory for which item is which.
        if !isFiltering, totalGroupCount > 1, let currentGroupIndex {
            Divider()

            Button("Move Group Up") {
                onMoveGroup(currentGroupIndex, currentGroupIndex - 1)
            }
            .disabled(currentGroupIndex == 0)

            Button("Move Group Down") {
                onMoveGroup(currentGroupIndex, currentGroupIndex + 1)
            }
            .disabled(currentGroupIndex == totalGroupCount - 1)
        }

        // Suppressed while filtering — the header reflects only the
        // matched subset, so a whole-group destructive action could
        // silently close hidden workspaces — and for unresolved or
        // stale rows (nil currentGroupIndex), where an ID-keyed
        // mutation could hit a different group than the one shown
        // (same gating rationale as Move Group above). Disabled
        // for the sole empty group: the store
        // refuses to remove the last group, so the action would be
        // a no-op.
        if !isFiltering, currentGroupIndex != nil {
            Divider()

            Button(SidebarGroupClosePolicy.actionLabel, role: .destructive) {
                onCloseGroup()
            }
            .disabled(
                SidebarGroupClosePolicy.closeIsDeadControl(
                    isGroupEmpty: group.sessions.isEmpty,
                    totalGroupCount: totalGroupCount
                ))
        }
    }

    @ViewBuilder
    private var groupAccessibilityActionsContent: some View {
        Button("New Workspace in Group") {
            onNewSessionInGroup()
        }

        Button("Connect via SSH…") {
            onConnectViaSSH(group)
        }

        Button("New Workspace Group…") {
            onNewGroup()
        }

        Button("Rename Workspace Group") {
            onRenameGroup()
        }

        // Mirror the Color submenu as a flat list of actions —
        // `.accessibilityActions` doesn't nest, so VoiceOver users
        // would otherwise have no path to set a group color. The
        // visual `.contextMenu` keeps the nested Color… submenu.
        //
        // Each action posts a WCAG 4.1.3 status announcement so VoiceOver confirms
        // the color change even when focus stays on the same header.
        if group.color != nil {
            Button("Clear Workspace Group Color") {
                setGroupColor(nil)
            }
        }
        ForEach(WorkspaceGroupColor.pickerCases, id: \.self) { color in
            if group.color != color {
                Button("Set Workspace Group Color to \(color.displayName)") {
                    setGroupColor(color)
                }
            }
        }

        // Group reorder is suppressed during filter, matching the
        // drag/drop gating. Filtering can hide intermediate groups,
        // so a Move Group action's notion of "up by one" against
        // the filtered projection wouldn't match the underlying
        // `sessionStore.groups` order it mutates. Also suppressed
        // when `currentGroupIndex` is nil (unresolved/dup-id row).
        if !isFiltering, let currentGroupIndex, currentGroupIndex > 0 {
            Button("Move Group Up") {
                onMoveGroup(currentGroupIndex, currentGroupIndex - 1)
            }
        }
        if !isFiltering, let currentGroupIndex, currentGroupIndex < totalGroupCount - 1 {
            Button("Move Group Down") {
                onMoveGroup(currentGroupIndex, currentGroupIndex + 1)
            }
        }

        // Omitted (rather than disabled) when inapplicable —
        // `.accessibilityActions` has no disabled state. Same
        // filtering + unresolved-row suppression as the context menu.
        if !isFiltering, currentGroupIndex != nil,
            !SidebarGroupClosePolicy.closeIsDeadControl(
                isGroupEmpty: group.sessions.isEmpty,
                totalGroupCount: totalGroupCount
            )
        {
            Button(SidebarGroupClosePolicy.actionLabel) {
                onCloseGroup()
            }
        }

        // The only interactive-content peek in the app without a non-mouse
        // path otherwise — mirrors `SidebarSessionTile`'s per-pane jump
        // actions (`PanePeekItem`) for the group roster peek card. Gated on
        // `displayMode == .collapsed` only — matching `canPeek` exactly, the
        // same trigger the mouse-hover path uses. A group's own `isCollapsed`
        // doesn't matter here: in the collapsed rail, a group's own tiles
        // (when `isCollapsed` is false) render as bare numbered squares with
        // no name text, so there's no redundancy with the peek card either
        // way — unlike the expanded rail, where an uncollapsed group already
        // exposes each workspace as an ordinary focusable/actionable row.
        if displayMode == .collapsed {
            ForEach(SessionPeekItem.items(for: sessions, activeSessionID: selectedSessionID)) { item in
                Button(groupSessionJumpActionLabel(item)) {
                    peekModel.onSelectGroupSession?(group.id, item.id)
                }
            }
        }
    }

    /// VoiceOver twin of the mouse-only group roster peek card row — mirrors
    /// `SidebarSessionTile.paneJumpActionLabel`'s shape for a `SessionPeekItem`
    /// instead of a `PanePeekItem`, so a VoiceOver "Jump to X" action carries
    /// the same state a sighted user reads off the card row (agent, status,
    /// remote, unread, active).
    private func groupSessionJumpActionLabel(_ item: SessionPeekItem) -> String {
        var parts = ["Jump to \(item.title)", item.agentShortName, item.state.label]
        if item.locationText != nil {
            parts.append(item.accessibilityLocationText)
        }
        if item.unread > 0 {
            parts.append(LocalizedPluralStrings.sidebarNotifications(count: item.unread))
        }
        if item.isActive {
            parts.append("active workspace")
        }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private var groupCollapsedStatusDot: some View {
        if let state = collapsedGroupAttention.primaryState {
            StatusDot(state)
                .accessibilityHidden(true)
        }
    }

    private var currentLegacyColor: WorkspaceGroupColor? {
        guard let color = group.color, !WorkspaceGroupColor.pickerCases.contains(color) else {
            return nil
        }
        return color
    }

    private func setGroupColor(_ color: WorkspaceGroupColor?) {
        onSetGroupColor(color)
        if let color {
            TerminalAccessibilityAnnouncer.announce(
                String(
                    localized: "Workspace group color set to \(color.displayName)",
                    comment:
                        "VoiceOver status message after setting a workspace group's color. The placeholder is a color name such as 'Teal' or 'Mauve'."
                )
            )
        } else {
            TerminalAccessibilityAnnouncer.announce(
                String(
                    localized: "Workspace group color cleared",
                    comment: "VoiceOver status message after clearing a workspace group's color."
                )
            )
        }
    }

    /// WCAG 2.5.8 minimum pointer target for the X, before `textScaleFactor`
    /// scales it up. This X is the sole pointer path to closing a group, so
    /// the base can't sit under the minimum and lean on a scaled-up user
    /// setting to reach it.
    static let closeTargetBaseSize: CGFloat = 24

    // This X is the only pointer path to closing a group, so it can't be
    // discoverable by hover alone in the state where hover is the least
    // likely gesture: an expanded empty group rests it visible. Everywhere
    // else it stays a hover reveal over the count badge, and the context menu
    // "Close Group" plus the header's "Close Group" accessibility action
    // (`groupAccessibilityActionsContent`) remain always-available.
    private var groupCloseButton: some View {
        Button(role: .destructive) {
            // Belt-and-braces with the opacity gate below: any activation path
            // that sidesteps pointer hit-testing (keyboard, or a future
            // synthesized action) still can't close a gated group.
            guard showsGroupCloseButton else { return }
            onCloseGroup()
        } label: {
            // Glyph + hit frame scale with the count badge (see
            // `textScaleFactor`) so a large text-size setting doesn't shrink
            // the X into a tiny mark beside a grown count (INT-237). The base
            // 9pt glyph is the X's own design size (the count renders at 11pt —
            // deliberately larger than the glyph); the frame is the POINTER
            // TARGET and carries the 24pt minimum. `textScaleFactor` is 1.0 at
            // 100%, so no scaling is applied there.
            Image(systemName: "xmark")
                .font(.system(size: 9 * textScaleFactor, weight: .bold))
                .frame(
                    width: Self.closeTargetBaseSize * textScaleFactor,
                    height: Self.closeTargetBaseSize * textScaleFactor
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // In the FKA focus order exactly while it is visible. An invisible X
        // that Tab can still reach and Space can still fire is the original
        // reason this was `focusable(false)`; a resting-visible X is ordinary
        // UI, and keyboard users get the same reach as the pointer.
        // (`accessibilityHidden` and `allowsHitTesting` do not remove a Button
        // from the FKA focus order — only `focusable` does.)
        .focusable(showsGroupCloseButton)
        .foregroundStyle(Color.aw.text)
        // Hidden-but-present (not `if`-removed) so the hover morph doesn't
        // insert/remove views.
        .opacity(showsGroupCloseButton ? 1 : 0)
        // Hit-testing follows visibility exactly: an X that is drawn but
        // ignores a click is its own bug. A rebuild can slide a resting X under
        // a stationary pointer, so a repeated click in one spot can close more
        // than one group — that is recoverable (`removeGroup` registers undo)
        // and gating on hover does not prevent it, because the arriving header
        // receives a genuine hover-enter.
        .allowsHitTesting(showsGroupCloseButton)
        .accessibilityHidden(true)
        // Emptied while hidden — AppKit skips empty tooltips, so the count
        // badge can't pop a close tooltip in the states where the X never
        // shows (filtering, unresolved row, sole empty group, collapsed rail).
        // "Close Group" matches the context menu and VoiceOver action names
        // for the same operation (consistent identification).
        .help(showsGroupCloseButton ? SidebarGroupClosePolicy.actionLabel : "")
    }

    private var groupAccessibilityValue: String {
        let disclosure = isCollapsed ? "Collapsed" : "Expanded"
        // Collapsed drops the rows from the accessibility tree, taking the
        // per-session state a VoiceOver user would otherwise hear with them.
        // Surface the aggregate here instead — the audible twin of the visible
        // collapsed-only header dot. Expanded omits it: the rows carry it, and
        // repeating it on the header would just be double-speak.
        let statePhrase = isCollapsed ? collapsedStatePhrase : ""
        guard let currentGroupIndex else {
            return disclosure + statePhrase
        }
        return "\(disclosure)\(statePhrase), group \(currentGroupIndex + 1) of \(totalGroupCount)"
    }

    /// Aggregate attention rollup for a collapsed group, shared by the wide-mode
    /// header dot (`groupCollapsedStatusDot`), the rail glyph badge
    /// (`RailGroupAttentionBadge`), and the VoiceOver phrase
    /// (`collapsedStatePhrase`) so all three agree on *which* states are present
    /// and which one wins. Each surface still renders differently — the wide
    /// `StatusDot` vs the rail glyph badge are deliberately distinct visuals —
    /// but the underlying signal they read can't drift between them.
    ///
    /// `.output` is intentionally excluded: it's a passive "there's output"
    /// state, not a group-level attention cue (it still shows in the footer's
    /// global overview). Add it here *and* to every consumer, or the channels
    /// drift apart.
    private var collapsedGroupAttention: CollapsedGroupAttention {
        var summary = CollapsedGroupAttention()
        for session in sessions {
            switch session.chromeAwState {
            case .needs: summary.needs += 1
            case .error: summary.error += 1
            case .thinking: summary.thinking += 1
            default: break
            }
        }
        return summary
    }

    /// VoiceOver twin of the visible collapsed-only signal. Voices the same
    /// states the badge/dot render so spoken and visual stay in lockstep.
    private var collapsedStatePhrase: String {
        let attention = collapsedGroupAttention
        var parts: [String] = []
        if attention.needs > 0 {
            parts.append(LocalizedPluralStrings.sidebarAgentsNeedInput(count: attention.needs))
        }
        if attention.error > 0 {
            parts.append(LocalizedPluralStrings.sidebarErrors(count: attention.error))
        }
        if attention.thinking > 0 {
            parts.append("\(attention.thinking) thinking")
        }
        return parts.isEmpty ? "" : ", " + parts.joined(separator: ", ")
    }

    /// macOS SwiftUI `Menu` items strip `.foregroundStyle()` from `Image`
    /// icons and re-color them in the menu text color — so an earlier
    /// attempt that used `Image(systemName: "circle.fill").foregroundStyle(swatch)`
    /// rendered every swatch in white. `Text` glyphs DO preserve per-segment
    /// foreground colour through Menu's styling pass, so the swatch is a
    /// Unicode bullet inside a colored `Text`, concatenated with the title.
    /// `swatch == nil` is the "Default" option — rendered as a hollow circle in
    /// the muted text tone.
    private func colorMenuLabel(_ title: String, swatch: Color?, isSelected: Bool) -> Text {
        let bullet: Text
        if let swatch {
            bullet = Text("●  ").foregroundStyle(swatch)
        } else {
            bullet = Text("○  ").foregroundStyle(Color.aw.text3)
        }
        return bullet + Text(isSelected ? "\(title) ✓" : title)
    }
}
