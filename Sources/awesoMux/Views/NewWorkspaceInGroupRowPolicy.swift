import AwesoMuxCore

/// The three ways the `+ new workspace` row differs between an empty group and
/// a populated one. Hoisted out of the call site so the differences live in one
/// reviewable place instead of three ternaries in `SidebarGroupView.body`
/// (same reason `SidebarGroupClosePolicy` exists).
enum NewWorkspaceInGroupRowPolicy {
    /// The row's persistent remove-group X.
    ///
    /// An empty group has no tiles and its header X is hover-only, so the row
    /// is its only always-visible removal path. A populated group already has
    /// the header's hover X, and two pointer paths to the same destructive
    /// action invites the wrong one being clicked.
    static func showsRemoveButton(isGroupEmpty: Bool, canRemoveGroup: Bool) -> Bool {
        isGroupEmpty && canRemoveGroup
    }

    /// The dashed resting border.
    ///
    /// It reads as "there's nothing here" for an empty group. With tiles above
    /// it, one dashed box per group is visual noise, so the row rests
    /// borderless and only lights up while drag-targeted.
    static func showsRestingBorder(isGroupEmpty: Bool) -> Bool {
        isGroupEmpty
    }

    /// Where a workspace dropped on the row lands.
    ///
    /// The row sits at the bottom of a populated group, so it must append —
    /// inserting at 0 would contradict the row's own position. An empty group
    /// has no tiles, so 0 and append name the same slot; 0 preserves the
    /// shipped behavior.
    static func dropInsertionIndex(isGroupEmpty: Bool) -> Int {
        isGroupEmpty ? 0 : SessionStore.appendIndex
    }
}
