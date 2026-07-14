import AwesoMuxCore
import DesignSystem
import SwiftUI

/// The synthetic Pinned section at the top of the sidebar. Not a real
/// SessionGroup: rows come from SidebarPinnedProjection, each tinted by its
/// ORIGIN group so a pinned tile keeps answering "which project is this?"
/// (INT-737). Not collapsible by design — the section's whole job is
/// visibility.
struct SidebarPinnedSectionView: View {
    let pinned: [PinnedSessionEntry]
    let density: SidebarDensity
    let displayMode: SidebarWidthMode
    let isFiltering: Bool
    let selectedSessionID: TerminalSession.ID?
    let allGroups: [SessionGroup]
    let jumpIndexBySessionID: [TerminalSession.ID: Int]
    let workspacesWithBackgroundedFloatingWork: Set<TerminalSession.ID>
    let duplicateDisambiguationBySessionID: [TerminalSession.ID: SidebarDuplicateDisambiguation]
    let onSelect: (TerminalSession) -> Void
    let onTogglePin: (TerminalSession) -> Void
    let onClose: (TerminalSession) -> Void
    let onClear: (TerminalSession) -> Void
    let onRename: (TerminalSession) -> Void
    let onAcknowledge: (TerminalSession) -> Void
    let onToggleNotificationsMute: (TerminalSession) -> Void
    let canMakeWorkspaceManaged: (TerminalSession) -> Bool
    let onMakeWorkspaceManaged: (TerminalSession) -> Void
    let onNewSessionHere: (TerminalSession) -> Void
    let onMoveToGroup: (TerminalSession.ID, SessionGroup.ID) -> Void
    /// Reorder within the pinned section (final-index convention, matching
    /// `SessionStore.movePinnedSession`). Powers both the tile's keyboard
    /// Move Up/Down actions and the pointer drag-reorder drop delegate.
    let onMovePinned: (Int, Int) -> Void
    let onWorkspaceDragStarted: (TerminalSession.ID) -> UUID
    let activeDragKind: SidebarDragKind?
    let activeDragID: UUID?
    let activeWorkspaceDragSourceID: TerminalSession.ID?
    let onDragRefreshed: (SidebarDragKind) -> Void
    let onDragEnded: () -> Void
    let onDragExited: () -> Void
    let focusedRowTarget: FocusState<SidebarVisibleRowTarget?>.Binding
    @Binding var isKeyboardNavigating: Bool

    @State private var rowFrames: [TerminalSession.ID: CGRect] = [:]
    @State private var dropIndex: Int?

    private var coordinateSpaceName: String { "sidebar-pinned-section" }

    var body: some View {
        let pinnedSessionIDs = pinned.map(\.entry.session.id)
        let pinnedSessionIDSet = Set(pinnedSessionIDs)

        VStack(alignment: .leading, spacing: density.sessionStackSpacing) {
            header
                .padding(.horizontal, displayMode == .collapsed ? 0 : 4)
                .padding(.bottom, density.groupHeaderBottomPadding)
                .frame(maxWidth: .infinity, alignment: .leading)

            pinnedTiles
                .coordinateSpace(name: coordinateSpaceName)
                .onPreferenceChange(SidebarRowFramePreferenceKey.self) { frames in
                    // Keep only frames for currently-visible pinned tiles so the
                    // y-hit-test never indexes against a stale row.
                    rowFrames = frames.filter { pinnedSessionIDSet.contains($0.key) }
                }
                .onChange(of: pinnedSessionIDs) { _, _ in
                    rowFrames = rowFrames.filter { pinnedSessionIDSet.contains($0.key) }
                    if dropIndex != nil {
                        dropIndex = nil
                    }
                }
                .overlay(alignment: .topLeading) {
                    if activeDragKind == .workspace,
                        !isFiltering,
                        let dropIndex,
                        let y = SidebarInsertionResolver.insertionY(
                            forInsertionIndex: dropIndex,
                            orderedIDs: pinnedSessionIDs,
                            frames: rowFrames,
                            spacing: density.sessionStackSpacing
                        )
                    {
                        SidebarInsertionIndicator(tint: Color.aw.mauve)
                            .offset(y: y - SidebarInsertionIndicator.height / 2)
                            .allowsHitTesting(false)
                    }
                }
                .sidebarDrop(
                    enabled: activeDragKind == .workspace && !isFiltering,
                    delegate: SidebarPinnedReorderDropDelegate(
                        pinnedSessionIDs: pinnedSessionIDs,
                        rowFrames: rowFrames,
                        isFiltering: isFiltering,
                        activeDragKind: activeDragKind,
                        activeDragID: activeDragID,
                        activeWorkspaceDragSourceID: activeWorkspaceDragSourceID,
                        setInsertionIndex: setDropIndex,
                        onMovePinned: onMovePinned,
                        onDragRefreshed: onDragRefreshed,
                        onDropEnded: {
                            dropIndex = nil
                            onDragEnded()
                        },
                        onDropExited: {
                            dropIndex = nil
                            onDragExited()
                        }
                    )
                )
        }
        .onChange(of: activeDragKind) { _, kind in
            if kind != .workspace {
                dropIndex = nil
            }
        }
        .onChange(of: isFiltering) { _, filtering in
            if filtering {
                dropIndex = nil
            }
        }
    }

    @ViewBuilder
    private var pinnedTiles: some View {
        VStack(alignment: .leading, spacing: density.sessionStackSpacing) {
            ForEach(Array(pinned.enumerated()), id: \.element.entry.session.id) { index, item in
                tile(for: item, at: index)
                    .help(
                        String(
                            localized: "Pinned from \(item.originGroup.name)",
                            comment: "Tooltip on a pinned sidebar workspace naming the group it belongs to."
                        )
                    )
                    // Per-tile frame cache for the y-hit-test, scoped to the
                    // pinned section's coordinate space.
                    .background(
                        GeometryReader { proxy in
                            Color.clear
                                .preference(
                                    key: SidebarRowFramePreferenceKey.self,
                                    value: [
                                        item.entry.session.id:
                                            proxy.frame(in: .named(coordinateSpaceName))
                                    ]
                                )
                        }
                    )
            }
        }
    }

    private func setDropIndex(_ index: Int?) {
        guard dropIndex != index else {
            return
        }
        dropIndex = index
    }

    @ViewBuilder
    private var header: some View {
        if displayMode == .collapsed {
            // Collapsed rail has no room for text; the glyph alone marks the
            // boundary between pinned tiles and the first group.
            Image(systemName: "pin.fill")
                .font(.system(size: 9, weight: .bold))
                // railText (not text3) so this small functional glyph clears AA
                // when the label is absent, matching the jump-digit precedent
                // on the mantle rail.
                .foregroundStyle(Color.aw.railText)
                .frame(width: 40)
                .frame(maxWidth: .infinity)
                .accessibilityLabel(
                    String(
                        localized: "Pinned",
                        comment: "Accessibility label for the pinned workspaces section header in the collapsed sidebar."
                    )
                )
                .accessibilityAddTraits(.isHeader)
        } else {
            // Mirror SidebarGroupView.groupHeader's expanded typography (the
            // pin glyph stands in for the group's chevron + tint marker; a
            // synthetic section has neither).
            HStack(spacing: 8) {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 8)
                    // Section marker on mantle; text3 fails Latte 1.4.11.
                    .foregroundStyle(Color.aw.railText)

                Text(String(localized: "Pinned", comment: "Sidebar section header for pinned workspaces."))
                    .awFont(AwFont.Mono.kicker)
                    .tracking(1)
                    .textCase(.uppercase)
                    .foregroundStyle(Color.aw.railText)
                    .lineLimit(1)

                Spacer(minLength: 4)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
        }
    }

    @ViewBuilder
    private func tile(for item: PinnedSessionEntry, at index: Int) -> some View {
        let session = item.entry.session
        SidebarSessionTile(
            session: session,
            match: item.entry.match,
            tint: ProjectTint(
                groupName: item.originGroup.name,
                color: item.originGroup.color,
                index: item.originGroupUnfilteredIndex
            ),
            isActive: session.id == selectedSessionID,
            displayMode: displayMode,
            isKeyboardFocused: focusedRowTarget.wrappedValue == .session(session.id),
            jumpIndex: jumpIndexBySessionID[session.id],
            hasBackgroundedFloatingWork:
                workspacesWithBackgroundedFloatingWork.contains(session.id),
            isPromotedInsertion: false,
            isPromotionPulseActive: false,
            isFiltering: isFiltering,
            duplicateDisambiguation: duplicateDisambiguationBySessionID[session.id],
            indexInGroup: index,
            sessionCountInGroup: pinned.count,
            ownerGroupIndex: item.originGroupUnfilteredIndex,
            // No prev/next-group move actions from the pinned section: the tile
            // isn't positioned relative to group neighbors here.
            previousNeighborGroup: nil,
            nextNeighborGroup: nil,
            otherGroups: allGroups.filter { $0.id != item.originGroup.id },
            verticalPadding: density.sessionTileVerticalPadding,
            onSelect: { onSelect(session) },
            onNewSessionHere: { onNewSessionHere(session) },
            onAcknowledge: { onAcknowledge(session) },
            onMoveWithinGroup: { onMovePinned(index, $0) },
            onMoveToGroup: { destinationGroupID in
                onMoveToGroup(session.id, destinationGroupID)
            },
            onClose: { onClose(session) },
            onClear: { onClear(session) },
            onRename: { onRename(session) },
            canMakeWorkspaceManaged: canMakeWorkspaceManaged(session),
            onMakeWorkspaceManaged: { onMakeWorkspaceManaged(session) },
            onToggleNotificationsMute: { onToggleNotificationsMute(session) },
            isPinned: true,
            onTogglePin: { onTogglePin(session) },
            pinnedOriginGroupName: item.originGroup.name,
            onDragStarted: { onWorkspaceDragStarted(session.id) },
            focusedRowTarget: focusedRowTarget,
            isKeyboardNavigatingValue: isKeyboardNavigating,
            isKeyboardNavigating: $isKeyboardNavigating
        )
        // Skips re-running this row's `body` (including its
        // `.accessibilityElement(children: .combine)` node) when an
        // unrelated row's store publish reconstructs this tile with
        // identical rendered inputs — see `SidebarSessionTile.RenderKey`.
        .equatable()
    }
}
