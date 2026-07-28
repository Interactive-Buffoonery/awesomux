import AwesoMuxConfig
import AwesoMuxCore
import DesignSystem
import SwiftUI

/// The synthetic Needs Input section at the top of the sidebar. Not a real
/// SessionGroup: rows come from SidebarAttentionProjection, each tinted by its
/// ORIGIN group so a lifted tile keeps answering "which project is this?".
/// Not collapsible and not reorderable by design — membership is computed and
/// transient, so there is no user-owned order to preserve.
struct SidebarAttentionSectionView: View {
    let attention: [LiftedSessionEntry]
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
    let onWorkspaceDragStarted: (TerminalSession.ID) -> UUID
    let focusedRowTarget: FocusState<SidebarVisibleRowTarget?>.Binding
    let focusedSearchSessionID: TerminalSession.ID?
    @Binding var isKeyboardNavigating: Bool

    // Read here (ungated) and passed into the tile as a compared snapshot —
    // in-tile store reads stale behind the tile's `.equatable()` gate (PR #428).
    @Environment(AppSettingsStore.self) private var appSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: density.sessionStackSpacing) {
            header
                .padding(.horizontal, displayMode == .collapsed ? 0 : 4)
                .padding(.bottom, density.groupHeaderBottomPadding)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: density.sessionStackSpacing) {
                ForEach(Array(attention.enumerated()), id: \.element.entry.session.id) { index, item in
                    tile(for: item, at: index)
                        .help(
                            String(
                                localized: "Needs input, from \(item.originGroup.name)",
                                comment:
                                    "Tooltip on a lifted sidebar workspace naming the group it returns to."
                            )
                        )
                }
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        if displayMode == .collapsed {
            // Collapsed rail has no room for text; the glyph alone marks the
            // boundary between lifted tiles and whatever follows.
            Image(systemName: "exclamationmark.bubble.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.aw.status.needs)
                .frame(width: 40)
                .frame(maxWidth: .infinity)
                .accessibilityLabel(
                    String(
                        localized: "Needs Input",
                        comment:
                            "Accessibility label for the needs-input workspaces section header in the collapsed sidebar."
                    )
                )
                .accessibilityAddTraits(.isHeader)
        } else {
            // Mirrors SidebarPinnedSectionView.header's typography; tinted peach
            // because every row in it is showing the needs cue.
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.bubble.fill")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 8)
                    .foregroundStyle(Color.aw.status.needs)

                Text(
                    String(
                        localized: "Needs Input",
                        comment: "Sidebar section header for workspaces awaiting user input."
                    )
                )
                .awFont(AwFont.Mono.kicker)
                .tracking(1)
                .textCase(.uppercase)
                .foregroundStyle(Color.aw.status.needs)
                .lineLimit(1)

                Spacer(minLength: 4)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
        }
    }

    @ViewBuilder
    private func tile(for item: LiftedSessionEntry, at index: Int) -> some View {
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
            showsSearchFocusCue: focusedSearchSessionID == session.id,
            jumpIndex: jumpIndexBySessionID[session.id],
            hasBackgroundedFloatingWork:
                workspacesWithBackgroundedFloatingWork.contains(session.id),
            isPromotedInsertion: false,
            isPromotionPulseActive: false,
            isFiltering: isFiltering,
            duplicateDisambiguation: duplicateDisambiguationBySessionID[session.id],
            indexInGroup: index,
            sessionCountInGroup: attention.count,
            ownerGroupIndex: item.originGroupUnfilteredIndex,
            // No prev/next-group move actions: a lifted tile isn't positioned
            // relative to group neighbors here.
            previousNeighborGroup: nil,
            nextNeighborGroup: nil,
            otherGroups: allGroups.filter { $0.id != item.originGroup.id },
            verticalPadding: density.sessionTileVerticalPadding,
            tintedHighContrast: appSettingsStore.appearance.value.tintedHighContrast,
            alwaysShowJumpNumbers: appSettingsStore.appearance.value.alwaysShowJumpNumbers,
            canReorderWithinGroup: false,
            onSelect: { onSelect(session) },
            onNewSessionHere: { onNewSessionHere(session) },
            onAcknowledge: { onAcknowledge(session) },
            onMoveWithinGroup: { _ in },
            onMoveToGroup: { destinationGroupID in
                onMoveToGroup(session.id, destinationGroupID)
            },
            onClose: { onClose(session) },
            onClear: { onClear(session) },
            onRename: { onRename(session) },
            canMakeWorkspaceManaged: canMakeWorkspaceManaged(session),
            onMakeWorkspaceManaged: { onMakeWorkspaceManaged(session) },
            onToggleNotificationsMute: { onToggleNotificationsMute(session) },
            isPinned: false,
            onTogglePin: { onTogglePin(session) },
            originGroupPhrase: String(
                localized: "Needs input, from \(item.originGroup.name)",
                comment:
                    "VoiceOver value fragment on a lifted sidebar workspace naming its origin group."
            ),
            // A real drag: a lifted tile is an ordinary unpinned workspace, so
            // dragging it into another group must work. Passing an inert stub
            // would leave a draggable tile whose drag can never land.
            onDragStarted: { onWorkspaceDragStarted(session.id) },
            focusedRowTarget: focusedRowTarget,
            isKeyboardNavigatingValue: isKeyboardNavigating,
            isKeyboardNavigating: $isKeyboardNavigating
        )
        .equatable()
        .id(session.id)
    }
}
