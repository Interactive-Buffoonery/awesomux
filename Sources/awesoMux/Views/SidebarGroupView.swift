import AwesoMuxConfig
import AwesoMuxCore
import DesignSystem
import SwiftUI

struct SidebarGroupView: View {
    let group: SessionGroup
    let entries: [SidebarSessionEntry]
    let density: SidebarDensity
    let tint: ProjectTint
    let workspacesWithBackgroundedFloatingWork: Set<TerminalSession.ID>
    let promotedSessionID: TerminalSession.ID?
    let promotionPulseSessionID: TerminalSession.ID?
    let isCollapsed: Bool
    let isFiltering: Bool
    let displayMode: SidebarWidthMode
    let duplicateDisambiguationBySessionID: [TerminalSession.ID: SidebarDuplicateDisambiguation]
    let allGroups: [SessionGroup]
    let jumpIndexBySessionID: [TerminalSession.ID: Int]
    let selectedSessionID: TerminalSession.ID?
    let onToggle: () -> Void
    let onSelect: (TerminalSession) -> Void
    let onNewSessionInGroup: () -> Void
    let onConnectViaSSH: (SessionGroup) -> Void
    let canMakeWorkspaceManaged: (TerminalSession) -> Bool
    let onMakeWorkspaceManaged: (TerminalSession) -> Void
    let onNewSessionHere: (TerminalSession) -> Void
    let onNewGroup: () -> Void
    let onRenameGroup: () -> Void
    let onSetGroupColor: (WorkspaceGroupColor?) -> Void
    /// The group's single close path: the header X, its context menu, and its
    /// VoiceOver action all route here, so the confirm-and-announce work in
    /// `closeWorkspaceGroup` can't be bypassed by one of them.
    let onCloseGroup: () -> Void
    let onAcknowledge: (TerminalSession) -> Void
    let onMoveSession: (TerminalSession.ID, SessionGroup.ID, Int) -> Void
    let onMoveGroup: (Int, Int) -> Void
    let activeDragKind: SidebarDragKind?
    let activeDragID: UUID?
    let activeWorkspaceDragSourceID: TerminalSession.ID?
    let activeWorkspaceDragSourceGroupID: SessionGroup.ID?
    /// True while the active workspace drag started from a pinned tile. Gates
    /// this group's drop targets off — pinned tiles reorder only within the
    /// pinned section in v1 (`SidebarPinnedReorderDropDelegate` owns them).
    let activeDragSourceIsPinned: Bool
    let onGroupDragStarted: (SessionGroup.ID) -> UUID
    let onWorkspaceDragStarted: (TerminalSession.ID) -> UUID
    let onDragRefreshed: (SidebarDragKind) -> Void
    let onDragEnded: () -> Void
    let onDragExited: () -> Void
    /// `nil` when this group's id isn't in the parent's lookup — a stale
    /// projection or a duplicate-ID snapshot (the lookup uniques on first
    /// occurrence). When nil, Move Group actions are suppressed so we
    /// can't mutate a different group than the one the user clicked.
    /// Neighbor / owner-index uses fall back to 0 internally.
    let currentGroupIndex: Int?
    let totalGroupCount: Int

    /// Fallback index for structural reads (neighbor refs, ownerGroupIndex
    /// passed to tiles) where landing on `0` for an unresolved group is
    /// preferable to threading Optional everywhere downstream. Move Group
    /// mutation paths read `currentGroupIndex` directly and gate on non-nil.
    private var resolvedGroupIndex: Int { currentGroupIndex ?? 0 }

    let onUncollapse: () -> Void
    let onClose: (TerminalSession) -> Void
    let onClear: (TerminalSession) -> Void
    let onRename: (TerminalSession) -> Void
    let onToggleNotificationsMute: (TerminalSession) -> Void
    let onTogglePin: (TerminalSession) -> Void
    let focusedRowTarget: FocusState<SidebarVisibleRowTarget?>.Binding
    let focusedSearchSessionID: TerminalSession.ID?
    @Binding var isKeyboardNavigating: Bool

    @State private var rowFrames: [TerminalSession.ID: CGRect] = [:]
    @State private var rowFrameCache = SidebarDragFrameCache<TerminalSession.ID>()
    @State private var workspaceDropIndex: Int?
    @State private var headerWorkspaceDropTargeted = false
    @State private var suppressedWorkspaceDragID: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // Read here (ungated) and passed into the tile as a compared snapshot —
    // in-tile store reads stale behind the tile's `.equatable()` gate (PR #428).
    @Environment(AppSettingsStore.self) private var appSettingsStore

    private var coordinateSpaceName: String { "sidebar-group-\(group.id.uuidString)" }

    /// "Other groups" for the context-menu `Move to Group…` picker — excludes self.
    private var otherGroups: [SessionGroup] {
        allGroups.filter { $0.id != group.id }
    }

    private var previousNeighborGroup: SessionGroup? {
        guard resolvedGroupIndex > 0 else { return nil }
        return allGroups[resolvedGroupIndex - 1]
    }

    private var nextNeighborGroup: SessionGroup? {
        guard resolvedGroupIndex < allGroups.count - 1 else { return nil }
        return allGroups[resolvedGroupIndex + 1]
    }

    var body: some View {
        let sessionIDs = entries.map(\.session.id)
        // Hoisted out of the tile loop below: every row passes the same value,
        // so evaluating the computed property per row rebuilt one array per
        // row — `allGroups.count` work multiplied by the row count, for a
        // result that cannot differ between rows.
        let rowOtherGroups = otherGroups
        // Reused by the frame-preference and onChange closures below so they
        // don't each rebuild the id list on every render / layout pass.
        let sessionIDSet = Set(sessionIDs)
        let dragRowFrames = rowFrameCache.frames(
            stored: rowFrames,
            isDragActive: activeDragID != nil
        )
        let structuralAnimation: Animation? =
            reduceMotion || isFiltering
            ? nil
            : .easeOut(duration: 0.14)

        VStack(alignment: .leading, spacing: density.sessionStackSpacing) {
            // The header lives in its own view so a hover enter/exit invalidates
            // only that subview — `isHeaderHovered` moved there with it. Left as
            // `@State` on `SidebarGroupView`, one pointer sweep re-evaluated this
            // whole `body` (and every `SidebarSessionTile` in the `ForEach`) per
            // group crossed. The drop modifiers stay here (below) because they
            // mutate this view's shared drop state (`headerWorkspaceDropTargeted`,
            // `workspaceDropIndex`) and don't read hover — moving them would only
            // buy binding churn, not fewer invalidations.
            SidebarGroupHeaderRow(
                group: group,
                entries: entries,
                density: density,
                tint: tint,
                isCollapsed: isCollapsed,
                isFiltering: isFiltering,
                displayMode: displayMode,
                selectedSessionID: selectedSessionID,
                currentGroupIndex: currentGroupIndex,
                totalGroupCount: totalGroupCount,
                isDragActive: activeDragKind != nil,
                onToggle: onToggle,
                onNewSessionInGroup: onNewSessionInGroup,
                onConnectViaSSH: onConnectViaSSH,
                onNewGroup: onNewGroup,
                onRenameGroup: onRenameGroup,
                onSetGroupColor: onSetGroupColor,
                onCloseGroup: onCloseGroup,
                onMoveGroup: onMoveGroup,
                onGroupDragStarted: onGroupDragStarted,
                focusedRowTarget: focusedRowTarget,
                isKeyboardNavigating: $isKeyboardNavigating
            )
            // The header accepts workspace drops as a broad target: expanded
            // groups insert at the top where the indicator appears, while
            // collapsed groups append then auto-expand. Group reorders are
            // owned by the sidebar stack-level delegate so header and stack
            // drops cannot double-apply one move.
            //
            // Legacy .onDrop is used because the drag source is legacy
            // `.onDrag { NSItemProvider }` — SwiftUI's Transferable
            // .dropDestination does not consistently bridge from raw
            // NSItemProvider on macOS 15.
            // Indicator above the bracket so it anchors to the header's real
            // bottom edge. BETWEEN the two paddings it would anchor to the
            // padded bottom and draw `sessionStackSpacing` too low; after
            // the reclaim it would also be correct, but this placement makes
            // the intent unambiguous without depending on reclaim order.
            .overlay(alignment: .bottom) {
                if activeDragKind == .workspace && !isFiltering && headerWorkspaceDropTargeted {
                    SidebarInsertionIndicator(tint: tint.hue)
                        .offset(y: SidebarInsertionIndicator.height / 2)
                        .allowsHitTesting(false)
                }
            }
            // Reach down through the header→first-tile gap so a workspace
            // drag crossing it never hits dead space (which fires
            // dropExited and blinks the insertion indicator out mid-aim).
            // Bottom-only keeps the origin put; the negative padding below
            // reclaims the layout space so nothing visually moves.
            .padding(.bottom, density.sessionStackSpacing)
            .sidebarDrop(
                enabled: activeDragKind == .workspace && !isFiltering && displayMode != .collapsed,
                delegate: SidebarWorkspaceHeaderDropDelegate(
                    groupID: group.id,
                    isCollapsed: isCollapsed,
                    isFiltering: isFiltering,
                    activeDragKind: activeDragKind,
                    activeDragID: activeDragID,
                    activeDragSourceIsPinned: activeDragSourceIsPinned,
                    setIsTargeted: setHeaderWorkspaceDropTargeted,
                    onUncollapse: onUncollapse,
                    onMoveSession: onMoveSession,
                    onDragRefreshed: onDragRefreshed,
                    onDropEnded: {
                        clearWorkspaceHoverState()
                        onDragEnded()
                    },
                    onDropExited: {
                        clearWorkspaceHoverState()
                        onDragExited()
                    }
                )
            )
            .padding(.bottom, -density.sessionStackSpacing)

            if !isCollapsed {
                VStack(spacing: density.sessionStackSpacing) {
                    ForEach(Array(entries.enumerated()), id: \.element.session.id) { offset, entry in
                        let session = entry.session
                        // Only this scope's body re-runs on a display-only
                        // title write — not the group, and not its other rows.
                        LiveTitleScope(sessionID: session.id, reads: .everything) { liveTitles in
                            sessionRow(
                                entry: entry,
                                offset: offset,
                                rowOtherGroups: rowOtherGroups,
                                liveTitles: liveTitles
                            )
                        }
                        .id(session.id)
                        // Per-tile frame cache for y-hit-test. One coordinate
                        // space scoped to the group avoids cross-group
                        // ambiguity when rows are lazy-evicted.
                        .background(
                            GeometryReader { proxy in
                                Color.clear
                                    .preference(
                                        key: SidebarRowFramePreferenceKey.self,
                                        value: [session.id: proxy.frame(in: .named(coordinateSpaceName))]
                                    )
                            }
                        )
                    }

                    // Hidden while filtering: the row's drop delegate already
                    // refuses filtered drags, but its BUTTON would still fire —
                    // creating a workspace that instantly fails the active
                    // filter and vanishes, which reads as a broken click. A
                    // create affordance that produces invisible results is
                    // worse than no affordance.
                    if displayMode != .collapsed, !isFiltering {
                        let isGroupEmpty = entries.isEmpty
                        NewWorkspaceInGroupRow(
                            isFiltering: isFiltering,
                            groupName: group.name,
                            ownsDropDelegate: NewWorkspaceInGroupRowPolicy.ownsDropDelegate(
                                isGroupEmpty: isGroupEmpty
                            ),
                            activeDragKind: activeDragKind,
                            activeDragID: activeDragID,
                            activeDragSourceIsPinned: activeDragSourceIsPinned,
                            verticalPadding: density.emptyGroupVerticalPadding,
                            onNewSessionInGroup: onNewSessionInGroup,
                            onDragRefreshed: onDragRefreshed,
                            onDragEnded: onDragEnded,
                            onDragExited: onDragExited,
                            onAcceptDrop: { sessionID in
                                onMoveSession(
                                    sessionID,
                                    group.id,
                                    NewWorkspaceInGroupRowPolicy.dropInsertionIndex(
                                        isGroupEmpty: isGroupEmpty
                                    )
                                )
                            }
                        )
                    }
                }
                .coordinateSpace(name: coordinateSpaceName)
                .animation(structuralAnimation, value: sessionIDs)
                .onPreferenceChange(SidebarRowFramePreferenceKey.self) { frames in
                    // Keep only frames for currently-visible sessions so the
                    // y-hit-test never indexes against a stale row.
                    let visibleFrames = frames.filter { sessionIDSet.contains($0.key) }
                    rowFrameCache.update(visibleFrames)
                    // Keep the reader live so SwiftUI can coalesce preference
                    // emission; only the @State write is drag-gated to avoid
                    // idle layout invalidating this whole group again.
                    guard activeDragID != nil else { return }
                    rowFrames = visibleFrames
                }
                .onChange(of: sessionIDs) { _, _ in
                    // Filter changes / group restructures invalidate cached
                    // frames; preference reporting will repopulate them on
                    // the next layout pass.
                    rowFrames = rowFrames.filter { sessionIDSet.contains($0.key) }
                    // Clear the held drop index on any change to the session
                    // list, not only when it shrinks past the index (a
                    // same-count reorder leaves a stale-but-in-range index).
                    if workspaceDropIndex != nil {
                        setWorkspaceDropIndex(nil)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if activeDragKind == .workspace,
                        !isFiltering,
                        let workspaceDropIndex,
                        let y = SidebarInsertionResolver.insertionY(
                            forInsertionIndex: workspaceDropIndex,
                            orderedIDs: sessionIDs,
                            frames: dragRowFrames,
                            spacing: density.sessionStackSpacing
                        )
                    {
                        SidebarInsertionIndicator(tint: tint.hue)
                            .offset(y: y - SidebarInsertionIndicator.height / 2)
                            .allowsHitTesting(false)
                    }
                }
                // Reach down through the inter-group gutter (LazyVStack spacing
                // in SidebarView owns it and its only delegate rejects workspace
                // drags), so a cross-group drag stays over a live target the
                // whole way. Bottom-only: row frames are measured in
                // `.named(coordinateSpaceName)` while DropInfo.location is
                // relative to this view, and padding only the bottom leaves the
                // shared top-left origin untouched — so no hit-test math moves.
                // `.padding(.top,)` here would offset every drop by half a gap.
                .padding(.bottom, density.groupStackSpacing)
                .sidebarDrop(
                    enabled: activeDragKind == .workspace && !isFiltering,
                    delegate: SidebarWorkspaceListDropDelegate(
                        groupID: group.id,
                        sessionIDs: sessionIDs,
                        rowFrames: dragRowFrames,
                        isFiltering: isFiltering,
                        activeDragKind: activeDragKind,
                        activeDragID: activeDragID,
                        activeWorkspaceDragSourceID: activeWorkspaceDragSourceID,
                        activeWorkspaceDragSourceGroupID: activeWorkspaceDragSourceGroupID,
                        activeDragSourceIsPinned: activeDragSourceIsPinned,
                        allowsCrossGroupMoves: displayMode != .collapsed,
                        setInsertionIndex: setWorkspaceDropIndex,
                        onMoveSession: onMoveSession,
                        onDragRefreshed: onDragRefreshed,
                        onDropEnded: {
                            clearWorkspaceHoverState(suppressingCurrentDrag: true)
                            onDragEnded()
                        },
                        onDropExited: {
                            clearWorkspaceHoverState()
                            onDragExited()
                        }
                    )
                )
                // Reclaim the space: keeping the reported frame identical means
                // collapsed groups keep their gutter (their tile stack isn't
                // rendered at all) and SidebarGroupFramePreferenceKey still
                // reports unchanged group frames, so group-reorder midY flip
                // points don't move.
                .padding(.bottom, -density.groupStackSpacing)
            }
        }
        .onChange(of: activeDragKind) { _, kind in
            if kind != .workspace {
                clearWorkspaceHoverState()
            }
            // The header's own hover reset on drag-start now lives in
            // `SidebarGroupHeaderRow` (it owns `isHeaderHovered`).
        }
        .onChange(of: activeDragID) { _, dragID in
            if dragID != nil {
                rowFrames = rowFrameCache.frames(stored: rowFrames, isDragActive: true)
            }
            if dragID != suppressedWorkspaceDragID {
                suppressedWorkspaceDragID = nil
            }
        }
        .onChange(of: isFiltering) { _, filtering in
            if filtering {
                clearWorkspaceHoverState()
            }
            // The header's own hover reset on filter change now lives in
            // `SidebarGroupHeaderRow` (it owns `isHeaderHovered`).
        }
    }

    private func setWorkspaceDropIndex(_ index: Int?) {
        if index != nil, activeDragID == nil {
            workspaceDropIndex = nil
            headerWorkspaceDropTargeted = false
            return
        }

        if index != nil, isCurrentWorkspaceDragSuppressed {
            workspaceDropIndex = nil
            headerWorkspaceDropTargeted = false
            return
        }

        guard workspaceDropIndex != index else {
            return
        }

        workspaceDropIndex = index
        if index != nil {
            headerWorkspaceDropTargeted = false
        }
    }

    private func setHeaderWorkspaceDropTargeted(_ targeted: Bool) {
        if targeted, activeDragID == nil {
            workspaceDropIndex = nil
            headerWorkspaceDropTargeted = false
            return
        }

        if targeted, isCurrentWorkspaceDragSuppressed {
            workspaceDropIndex = nil
            headerWorkspaceDropTargeted = false
            return
        }

        guard headerWorkspaceDropTargeted != targeted else {
            return
        }

        headerWorkspaceDropTargeted = targeted
        if targeted {
            workspaceDropIndex = nil
        }
    }

    private func clearWorkspaceHoverState(suppressingCurrentDrag: Bool = false) {
        if suppressingCurrentDrag, let activeDragID {
            suppressedWorkspaceDragID = activeDragID
        }
        workspaceDropIndex = nil
        headerWorkspaceDropTargeted = false
    }

    private var isCurrentWorkspaceDragSuppressed: Bool {
        activeDragID != nil && activeDragID == suppressedWorkspaceDragID
    }

    /// One workspace row. Split out of the `ForEach` above so the row can sit
    /// inside a `LiveTitleScope` without nesting its whole construction one
    /// level deeper.
    @ViewBuilder
    private func sessionRow(
        entry: SidebarSessionEntry,
        offset: Int,
        rowOtherGroups: [SessionGroup],
        liveTitles: LiveTitles
    ) -> some View {
        let session = entry.session
        SidebarSessionTile(
            session: session,
            match: entry.match,
            tint: tint,
            isActive: selectedSessionID == session.id,
            displayMode: displayMode,
            isKeyboardFocused: focusedRowTarget.wrappedValue == .session(session.id),
            showsSearchFocusCue: focusedSearchSessionID == session.id,
            jumpIndex: jumpIndexBySessionID[session.id],
            hasBackgroundedFloatingWork:
                workspacesWithBackgroundedFloatingWork.contains(session.id),
            isPromotedInsertion: promotedSessionID == session.id,
            isPromotionPulseActive: promotionPulseSessionID == session.id,
            isFiltering: isFiltering,
            duplicateDisambiguation:
                duplicateDisambiguationBySessionID[session.id],
            indexInGroup: offset,
            sessionCountInGroup: entries.count,
            ownerGroupIndex: resolvedGroupIndex,
            previousNeighborGroup: previousNeighborGroup,
            nextNeighborGroup: nextNeighborGroup,
            otherGroups: rowOtherGroups,
            verticalPadding: density.sessionTileVerticalPadding,
            tintedHighContrast: appSettingsStore.appearance.value.tintedHighContrast,
            alwaysShowJumpNumbers: appSettingsStore.appearance.value.alwaysShowJumpNumbers,
            onSelect: {
                onSelect(session)
            },
            onNewSessionHere: {
                onNewSessionHere(session)
            },
            onAcknowledge: {
                onAcknowledge(session)
            },
            onMoveWithinGroup: { newIndex in
                onMoveSession(session.id, group.id, newIndex)
            },
            onMoveToGroup: { destinationGroupID in
                onMoveSession(session.id, destinationGroupID, SessionStore.appendIndex)
            },
            onClose: {
                onClose(session)
            },
            onClear: {
                onClear(session)
            },
            onRename: {
                onRename(session)
            },
            canMakeWorkspaceManaged: canMakeWorkspaceManaged(session),
            onMakeWorkspaceManaged: {
                onMakeWorkspaceManaged(session)
            },
            onToggleNotificationsMute: {
                onToggleNotificationsMute(session)
            },
            isPinned: false,
            onTogglePin: {
                onTogglePin(session)
            },
            onDragStarted: {
                onWorkspaceDragStarted(session.id)
            },
            focusedRowTarget: focusedRowTarget,
            isKeyboardNavigatingValue: isKeyboardNavigating,
            liveTitles: liveTitles,
            isKeyboardNavigating: $isKeyboardNavigating
        )
        // Skips re-running this row's `body` (including its
        // `.accessibilityElement(children: .combine)` node)
        // when an unrelated row's store publish reconstructs
        // this tile with identical rendered inputs — see
        // `SidebarSessionTile.RenderKey`.
        .equatable()
    }
}
