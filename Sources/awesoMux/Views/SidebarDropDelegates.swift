import AwesoMuxCore
import DesignSystem
import SwiftUI
import UniformTypeIdentifiers

struct SidebarGroupReorderDropDelegate: DropDelegate {
    let groupIDs: [SessionGroup.ID]
    let groupFrames: [SessionGroup.ID: CGRect]
    let isFiltering: Bool
    let activeDragKind: SidebarDragKind?
    let activeDragID: UUID?
    let activeGroupDragSourceID: SessionGroup.ID?
    let setInsertionIndex: (Int?) -> Void
    let onMoveGroup: (SessionGroup.ID, Int) -> Void
    let onDragRefreshed: (SidebarDragKind) -> Void
    let onDropEnded: () -> Void
    let onDropExited: () -> Void

    func validateDrop(info: DropInfo) -> Bool {
        !isFiltering
            && activeDragKind == .group
            && activeDragID != nil
            && info.hasItemsConforming(to: [UTType.utf8PlainText])
    }

    func dropEntered(info: DropInfo) {
        updateInsertionIndex(info: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard updateInsertionIndex(info: info) else {
            return nil
        }
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        setInsertionIndex(nil)
        onDropExited()
    }

    func performDrop(info: DropInfo) -> Bool {
        defer { onDropEnded() }
        guard validateDrop(info: info),
              let provider = info.itemProviders(for: [UTType.utf8PlainText]).first else {
            return false
        }

        // Hold the drop if the frame cache isn't populated yet rather than
        // letting the resolver bias to the end of the list (Codex #3).
        guard let preRemovalIndex = insertionIndex(for: info.location.y) else {
            return false
        }
        let expectedDragID = activeDragID
        decodeWorkspaceGroupDragItem(from: provider) { item in
            guard item.dragID == expectedDragID else {
                return
            }
            onMoveGroup(item.groupID, preRemovalIndex)
        }
        return true
    }

    @discardableResult
    private func updateInsertionIndex(info: DropInfo) -> Bool {
        guard validateDrop(info: info) else {
            setInsertionIndex(nil)
            return false
        }
        onDragRefreshed(.group)
        setInsertionIndex(visibleInsertionIndex(for: info.location.y))
        return true
    }

    private func insertionIndex(for y: CGFloat) -> Int? {
        SidebarInsertionResolver.insertionIndex(
            forDropY: y,
            orderedIDs: groupIDs,
            frames: groupFrames
        )
    }

    private func visibleInsertionIndex(for y: CGFloat) -> Int? {
        guard let candidate = insertionIndex(for: y) else {
            return nil
        }
        return SidebarInsertionResolver.visibleReorderInsertionIndex(
            candidateIndex: candidate,
            sourceID: activeGroupDragSourceID,
            orderedIDs: groupIDs
        )
    }
}

struct SidebarWorkspaceListDropDelegate: DropDelegate {
    let groupID: SessionGroup.ID
    let sessionIDs: [TerminalSession.ID]
    let rowFrames: [TerminalSession.ID: CGRect]
    let isFiltering: Bool
    let activeDragKind: SidebarDragKind?
    let activeDragID: UUID?
    let activeWorkspaceDragSourceID: TerminalSession.ID?
    let activeWorkspaceDragSourceGroupID: SessionGroup.ID?
    /// True while the active workspace drag started from a pinned tile.
    /// Pin/unpin via drag across the pinned-section boundary is out of scope
    /// for v1, so a group target must not light up or accept during a pinned
    /// drag — the pinned-section delegate owns those drops.
    let activeDragSourceIsPinned: Bool
    let allowsCrossGroupMoves: Bool
    let setInsertionIndex: (Int?) -> Void
    let onMoveSession: (TerminalSession.ID, SessionGroup.ID, Int) -> Void
    let onDragRefreshed: (SidebarDragKind) -> Void
    let onDropEnded: () -> Void
    let onDropExited: () -> Void

    func validateDrop(info: DropInfo) -> Bool {
        guard !activeDragSourceIsPinned else { return false }
        return !isFiltering
            && activeDragKind == .workspace
            && activeDragID != nil
            && (allowsCrossGroupMoves || activeWorkspaceDragSourceGroupID == groupID)
            && info.hasItemsConforming(to: [UTType.utf8PlainText])
    }

    func dropEntered(info: DropInfo) {
        updateInsertionIndex(info: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard updateInsertionIndex(info: info) else {
            return nil
        }
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        setInsertionIndex(nil)
        onDropExited()
    }

    func performDrop(info: DropInfo) -> Bool {
        defer { onDropEnded() }
        guard validateDrop(info: info),
              let provider = info.itemProviders(for: [UTType.utf8PlainText]).first else {
            return false
        }

        // Hold the drop until row frames are cached rather than biasing to
        // the end of the list (Codex #3).
        guard let preRemovalIndex = insertionIndex(for: info.location.y) else {
            return false
        }
        let dropPoint = info.location
        let capturedSessionIDs = sessionIDs
        let capturedRowFrames = rowFrames
        let expectedDragID = activeDragID
        decodeWorkspaceDragItem(from: provider) { item in
            guard item.dragID == expectedDragID else {
                return
            }
            guard let targetIndex = SidebarInsertionResolver.workspacePostRemovalTargetIndex(
                sourceID: item.sessionID,
                dropPoint: dropPoint,
                preRemovalIndex: preRemovalIndex,
                orderedIDs: capturedSessionIDs,
                frames: capturedRowFrames
            ) else {
                return
            }
            onMoveSession(item.sessionID, groupID, targetIndex)
        }
        return true
    }

    @discardableResult
    private func updateInsertionIndex(info: DropInfo) -> Bool {
        guard validateDrop(info: info) else {
            setInsertionIndex(nil)
            return false
        }
        onDragRefreshed(.workspace)
        setInsertionIndex(visibleInsertionIndex(for: info.location.y))
        return true
    }

    private func insertionIndex(for y: CGFloat) -> Int? {
        SidebarInsertionResolver.insertionIndex(
            forDropY: y,
            orderedIDs: sessionIDs,
            frames: rowFrames
        )
    }

    private func visibleInsertionIndex(for y: CGFloat) -> Int? {
        guard let candidate = insertionIndex(for: y) else {
            return nil
        }
        return SidebarInsertionResolver.visibleReorderInsertionIndex(
            candidateIndex: candidate,
            sourceID: activeWorkspaceDragSourceID,
            orderedIDs: sessionIDs
        )
    }
}

struct SidebarWorkspaceHeaderDropDelegate: DropDelegate {
    let groupID: SessionGroup.ID
    let isCollapsed: Bool
    let isFiltering: Bool
    let activeDragKind: SidebarDragKind?
    let activeDragID: UUID?
    /// See `SidebarWorkspaceListDropDelegate.activeDragSourceIsPinned` — a
    /// pinned-sourced drag must not target group chrome in v1.
    let activeDragSourceIsPinned: Bool
    let setIsTargeted: (Bool) -> Void
    let onUncollapse: () -> Void
    let onMoveSession: (TerminalSession.ID, SessionGroup.ID, Int) -> Void
    let onDragRefreshed: (SidebarDragKind) -> Void
    let onDropEnded: () -> Void
    let onDropExited: () -> Void

    func validateDrop(info: DropInfo) -> Bool {
        guard !activeDragSourceIsPinned else { return false }
        return !isFiltering
            && activeDragKind == .workspace
            && activeDragID != nil
            && info.hasItemsConforming(to: [UTType.utf8PlainText])
    }

    func dropEntered(info: DropInfo) {
        updateTargeted(info: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard updateTargeted(info: info) else {
            return nil
        }
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        setIsTargeted(false)
        onDropExited()
    }

    func performDrop(info: DropInfo) -> Bool {
        defer { onDropEnded() }
        guard validateDrop(info: info),
              let provider = info.itemProviders(for: [UTType.utf8PlainText]).first else {
            return false
        }

        // Always insert at the top of the group so the landing position
        // matches the header insertion indicator (which renders at the
        // header's bottom edge = top of the group's content). Collapsed
        // groups expand first; previously they appended to the bottom,
        // contradicting the indicator.
        let expectedDragID = activeDragID
        decodeWorkspaceDragItem(from: provider) { item in
            guard item.dragID == expectedDragID else {
                return
            }
            if isCollapsed { onUncollapse() }
            onMoveSession(item.sessionID, groupID, 0)
        }
        return true
    }

    @discardableResult
    private func updateTargeted(info: DropInfo) -> Bool {
        guard validateDrop(info: info) else {
            setIsTargeted(false)
            return false
        }
        onDragRefreshed(.workspace)
        setIsTargeted(true)
        return true
    }
}

struct SidebarEmptyWorkspaceDropDelegate: DropDelegate {
    let isFiltering: Bool
    let activeDragKind: SidebarDragKind?
    let activeDragID: UUID?
    /// See `SidebarWorkspaceListDropDelegate.activeDragSourceIsPinned` — a
    /// pinned-sourced drag must not target an empty group in v1.
    let activeDragSourceIsPinned: Bool
    let setIsTargeted: (Bool) -> Void
    let onAcceptDrop: (TerminalSession.ID) -> Void
    let onDragRefreshed: (SidebarDragKind) -> Void
    let onDropEnded: () -> Void
    let onDropExited: () -> Void

    func validateDrop(info: DropInfo) -> Bool {
        guard !activeDragSourceIsPinned else { return false }
        return !isFiltering
            && activeDragKind == .workspace
            && activeDragID != nil
            && info.hasItemsConforming(to: [UTType.utf8PlainText])
    }

    func dropEntered(info: DropInfo) {
        updateTargeted(info: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard updateTargeted(info: info) else {
            return nil
        }
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        setIsTargeted(false)
        onDropExited()
    }

    func performDrop(info: DropInfo) -> Bool {
        defer { onDropEnded() }
        guard validateDrop(info: info),
              let provider = info.itemProviders(for: [UTType.utf8PlainText]).first else {
            return false
        }

        let expectedDragID = activeDragID
        decodeWorkspaceDragItem(from: provider) { item in
            guard item.dragID == expectedDragID else {
                return
            }
            onAcceptDrop(item.sessionID)
        }
        return true
    }

    @discardableResult
    private func updateTargeted(info: DropInfo) -> Bool {
        guard validateDrop(info: info) else {
            setIsTargeted(false)
            return false
        }
        onDragRefreshed(.workspace)
        setIsTargeted(true)
        return true
    }
}

/// Reorders tiles inside the synthetic Pinned section. Accepts only drags
/// that STARTED from a pinned tile — pin/unpin via drag across the section
/// boundary is deliberately out of scope for v1 (context menu covers it),
/// so an unpinned workspace drag must not target this section, and a pinned
/// drag must not target groups (gated in the group delegates).
///
/// Mirrors `SidebarWorkspaceListDropDelegate` exactly: same validateDrop
/// discipline, same held-drop-until-frames-cached guard, same post-removal
/// index conversion. `onMovePinned` takes the FINAL post-removal index
/// (matching `SessionStore.movePinnedSession`'s `moveGroup` convention), so
/// the resolver's `workspacePostRemovalTargetIndex` output feeds it directly.
struct SidebarPinnedReorderDropDelegate: DropDelegate {
    let pinnedSessionIDs: [TerminalSession.ID]
    let rowFrames: [TerminalSession.ID: CGRect]
    let isFiltering: Bool
    let activeDragKind: SidebarDragKind?
    let activeDragID: UUID?
    let activeWorkspaceDragSourceID: TerminalSession.ID?
    let setInsertionIndex: (Int?) -> Void
    let onMovePinned: (Int, Int) -> Void
    let onDragRefreshed: (SidebarDragKind) -> Void
    let onDropEnded: () -> Void
    let onDropExited: () -> Void

    func validateDrop(info: DropInfo) -> Bool {
        // Leads with `!isFiltering`: under a filter the pinned section shows
        // only matching tiles, so visible indices diverge from the backing
        // pinned order — same reason the group delegates reject while
        // filtering.
        guard !isFiltering,
              activeDragKind == .workspace,
              activeDragID != nil,
              let sourceID = activeWorkspaceDragSourceID,
              pinnedSessionIDs.contains(sourceID),
              info.hasItemsConforming(to: [UTType.utf8PlainText]) else {
            return false
        }
        return true
    }

    func dropEntered(info: DropInfo) {
        updateInsertionIndex(info: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard updateInsertionIndex(info: info) else {
            return nil
        }
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        setInsertionIndex(nil)
        onDropExited()
    }

    func performDrop(info: DropInfo) -> Bool {
        defer { onDropEnded() }
        guard validateDrop(info: info),
              let provider = info.itemProviders(for: [UTType.utf8PlainText]).first else {
            return false
        }

        // Hold the drop until row frames are cached rather than biasing to
        // the end of the list (mirrors the list delegate).
        guard let preRemovalIndex = insertionIndex(for: info.location.y) else {
            return false
        }
        let dropPoint = info.location
        let capturedPinnedIDs = pinnedSessionIDs
        let capturedRowFrames = rowFrames
        let expectedDragID = activeDragID
        decodeWorkspaceDragItem(from: provider) { item in
            guard item.dragID == expectedDragID else {
                return
            }
            guard let fromIndex = capturedPinnedIDs.firstIndex(of: item.sessionID) else {
                return
            }
            // Convert the pre-removal insertion point to the final index the
            // element occupies after it's pulled out (nil = dropped on itself).
            guard let targetIndex = SidebarInsertionResolver.workspacePostRemovalTargetIndex(
                sourceID: item.sessionID,
                dropPoint: dropPoint,
                preRemovalIndex: preRemovalIndex,
                orderedIDs: capturedPinnedIDs,
                frames: capturedRowFrames
            ) else {
                return
            }
            onMovePinned(fromIndex, targetIndex)
        }
        return true
    }

    @discardableResult
    private func updateInsertionIndex(info: DropInfo) -> Bool {
        guard validateDrop(info: info) else {
            setInsertionIndex(nil)
            return false
        }
        onDragRefreshed(.workspace)
        setInsertionIndex(visibleInsertionIndex(for: info.location.y))
        return true
    }

    private func insertionIndex(for y: CGFloat) -> Int? {
        SidebarInsertionResolver.insertionIndex(
            forDropY: y,
            orderedIDs: pinnedSessionIDs,
            frames: rowFrames
        )
    }

    private func visibleInsertionIndex(for y: CGFloat) -> Int? {
        guard let candidate = insertionIndex(for: y) else {
            return nil
        }
        return SidebarInsertionResolver.visibleReorderInsertionIndex(
            candidateIndex: candidate,
            sourceID: activeWorkspaceDragSourceID,
            orderedIDs: pinnedSessionIDs
        )
    }
}

struct EmptyGroupDropTarget: View {
    let isFiltering: Bool
    let canRemoveGroup: Bool
    let activeDragKind: SidebarDragKind?
    let activeDragID: UUID?
    let activeDragSourceIsPinned: Bool
    let verticalPadding: CGFloat
    let onNewSessionInGroup: () -> Void
    let onRemoveGroup: () -> Void
    let onDragRefreshed: (SidebarDragKind) -> Void
    let onDragEnded: () -> Void
    let onDragExited: () -> Void
    let onAcceptDrop: (TerminalSession.ID) -> Void

    @State private var isDropTargeted = false

    var body: some View {
        ZStack {
            Button {
                onNewSessionInGroup()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 14)

                    Text("new workspace")
                        .awFont(AwFont.Mono.pill)

                    Spacer(minLength: 4)

                    // Reserve trailing space for the sibling remove button so
                    // hit-test routing isn't ambiguous with the row tap.
                    if canRemoveGroup {
                        Color.clear.frame(width: 18, height: 18)
                    }
                }
                .foregroundStyle(Color.aw.textFaint)
                .padding(.horizontal, 8)
                .padding(.vertical, verticalPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.aw.surface.elevated.opacity(0.55), in: RoundedRectangle(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(
                            activeDragKind == .workspace && isDropTargeted
                                ? Color.aw.mauve.opacity(0.90)
                                : Color.aw.border2.opacity(0.75),
                            style: StrokeStyle(
                                lineWidth: activeDragKind == .workspace && isDropTargeted ? 1.25 : 0.75,
                                dash: [3, 3]
                            )
                        )
                }
            }
            .buttonStyle(.plain)
            .help("New Workspace in Group")
            .accessibilityLabel("New workspace in empty group")

            // Sibling overlay (mirrors SidebarSessionTile.closeButton pattern)
            // so nested Buttons don't confuse hit-test routing.
            if canRemoveGroup {
                HStack {
                    Spacer()
                    Button(role: .destructive) {
                        onRemoveGroup()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.aw.text3)
                    .padding(.trailing, 8)
                    .accessibilityLabel(SidebarGroupClosePolicy.actionLabel)
                    .help(SidebarGroupClosePolicy.actionLabel)
                }
            }
        }
        .sidebarDrop(
            enabled: activeDragKind == .workspace && !isFiltering,
            delegate: SidebarEmptyWorkspaceDropDelegate(
                isFiltering: isFiltering,
                activeDragKind: activeDragKind,
                activeDragID: activeDragID,
                activeDragSourceIsPinned: activeDragSourceIsPinned,
                setIsTargeted: setDropTargeted,
                onAcceptDrop: onAcceptDrop,
                onDragRefreshed: onDragRefreshed,
                onDropEnded: {
                    clearDropTarget()
                    onDragEnded()
                },
                onDropExited: {
                    clearDropTarget()
                    onDragExited()
                }
            )
        )
        .onChange(of: activeDragKind) { _, kind in
            if kind != .workspace {
                clearDropTarget()
            }
        }
        .onChange(of: isFiltering) { _, filtering in
            if filtering {
                clearDropTarget()
            }
        }
    }

    private func setDropTargeted(_ targeted: Bool) {
        guard isDropTargeted != targeted else {
            return
        }

        isDropTargeted = targeted
    }

    private func clearDropTarget() {
        isDropTargeted = false
    }
}
