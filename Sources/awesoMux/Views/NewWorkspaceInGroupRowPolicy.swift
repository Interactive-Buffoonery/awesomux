import AwesoMuxCore

/// The two ways the `+ new workspace` row differs between an empty group and a
/// populated one. Hoisted out of the call site so the differences live in one
/// reviewable place instead of ternaries in `SidebarGroupView.body`
/// (same reason `SidebarGroupClosePolicy` exists).
///
/// Both remaining differences are about DROP behavior, which genuinely differs:
/// an empty group has no tiles, so the row is its only drop target. A third
/// difference — a dashed resting border on empty groups only — was removed
/// because it was purely cosmetic and made one control read as two.
///
/// The row used to carry a fourth: a persistent remove-group X, which existed
/// only because the header's X was hover-only and an empty group therefore had
/// no resting removal path. `SidebarGroupClosePolicy` now rests that X visible
/// for an expanded empty group, so the row's duplicate is gone — a row whose
/// whole purpose is creating a workspace is the wrong place to put the control
/// that destroys the group.
enum NewWorkspaceInGroupRowPolicy {
    /// Where a workspace dropped on the row lands.
    ///
    /// The row sits at the bottom of a populated group, so it must append —
    /// inserting at 0 would contradict the row's own position. An empty group
    /// has no tiles, so 0 and append name the same slot; 0 preserves the
    /// shipped behavior.
    static func dropInsertionIndex(isGroupEmpty: Bool) -> Int {
        isGroupEmpty ? 0 : SessionStore.appendIndex
    }

    /// Whether the row carries its OWN drop delegate.
    ///
    /// Empty groups must: with no tiles, the list delegate's resolver returns nil
    /// and deliberately holds the drop, so the row is the group's only drop target.
    /// Populated groups must not: the row sits below the last tile, where the list
    /// delegate already resolves to append, and a nested delegate there produces two
    /// competing affordances that flip-flop as the pointer crosses the boundary.
    static func ownsDropDelegate(isGroupEmpty: Bool) -> Bool {
        isGroupEmpty
    }
}
