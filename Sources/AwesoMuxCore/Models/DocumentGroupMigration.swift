import Foundation

/// Pure v4→v5 layout migration for INT-748 (documents became tabs).
///
/// Layer 1 of the migration is shape-level and lives in
/// `TerminalPaneLayout.init(from:)`: each legacy `.document` leaf decodes into a
/// single-tab `DocumentGroup` at its original split position, so a pre-v5
/// snapshot is structurally valid before this code runs.
///
/// Layer 2 — this type — is session-level and version-gated (literal `< 5` in
/// `TerminalSession.init(from:)`):
///
/// 1. **Backfill**: every tab with a nil `associatedTerminalPaneID` adopts its
///    group's split-adjacent terminal (`nearestTerminalSibling(ofDocumentGroup:)`),
///    computed while each single-tab group still sits at its original split
///    position — adjacency is exactly what pre-v5 send routing targeted, so each
///    document keeps the terminal it was actually next to.
/// 2. **Fold**: multiple groups merge into one. The first group in tree order
///    keeps its split position and fraction; later groups' tabs append in tree
///    order and their leaves collapse out. The first tab is selected for
///    determinism.
///
/// The version gate matters for the backfill specifically: in v5+ data a nil
/// association has a narrower live-send recovery path and a dangling explicit
/// association legitimately means "fail closed"; re-inferring adjacency would
/// resurrect a dead association.
public enum DocumentGroupMigration {
    /// Returns the migrated layout, or the input unchanged when it holds no
    /// document groups.
    public static func migratingLegacyDocumentLeaves(
        in layout: TerminalPaneLayout
    ) -> TerminalPaneLayout {
        var groups: [DocumentGroup] = []
        appendDocumentGroups(in: layout, into: &groups)
        guard !groups.isEmpty else {
            return layout
        }

        // Backfill nil associations from split adjacency BEFORE any folding
        // moves a group away from the split that defined its old routing.
        let backfilled = groups.map { group in
            var group = group
            let adjacentTerminalID = layout.nearestTerminalSibling(ofDocumentGroup: group.id)
            group.tabs = group.tabs.map { tab in
                var tab = tab
                if tab.associatedTerminalPaneID == nil {
                    tab.associatedTerminalPaneID = adjacentTerminalID
                }
                return tab
            }
            return group
        }

        var backfilledLayout = layout
        for group in backfilled {
            backfilledLayout =
                backfilledLayout.replacingDocumentGroup(id: group.id, with: group)
                ?? backfilledLayout
        }
        return foldingDocumentGroups(in: backfilledLayout)
    }

    /// Folds corrupt layouts with multiple groups without inferring legacy
    /// terminal associations. The first group keeps its position and later
    /// tabs append in tree order.
    public static func foldingDocumentGroups(
        in layout: TerminalPaneLayout
    ) -> TerminalPaneLayout {
        var groups: [DocumentGroup] = []
        appendDocumentGroups(in: layout, into: &groups)
        guard let primary = groups.first, groups.count > 1 else {
            return layout
        }

        let mergedTabs = groups.flatMap(\.tabs)
        let merged = DocumentGroup(
            id: primary.id,
            tabs: mergedTabs,
            selectedTabID: mergedTabs[0].id
        )

        // Collapse the later groups' leaves first, then swap the merged group
        // into the primary position.
        var result = layout
        for group in groups.dropFirst() {
            result = result.removingDocumentGroup(id: group.id) ?? result
        }
        return result.replacingDocumentGroup(id: primary.id, with: merged) ?? result
    }

    private static func appendDocumentGroups(
        in layout: TerminalPaneLayout,
        into groups: inout [DocumentGroup]
    ) {
        switch layout {
        case .pane:
            break
        case let .documentGroup(group):
            groups.append(group)
        case let .split(split):
            appendDocumentGroups(in: split.first, into: &groups)
            appendDocumentGroups(in: split.second, into: &groups)
        }
    }
}
