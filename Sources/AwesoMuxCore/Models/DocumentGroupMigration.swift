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
        var seenGroupIDs = Set<DocumentGroup.ID>()
        let normalizedLayout = normalizingDocumentGroupIDs(
            in: layout,
            seenGroupIDs: &seenGroupIDs
        )
        var groups: [DocumentGroup] = []
        appendDocumentGroups(in: normalizedLayout, into: &groups)
        guard !groups.isEmpty else {
            return layout
        }

        let backfilled = groups.map { group in
            var group = group
            let adjacentTerminalID = normalizedLayout.nearestTerminalSibling(
                ofDocumentGroup: group.id
            )
            group.tabs = group.tabs.map { tab in
                var tab = tab
                if tab.associatedTerminalPaneID == nil {
                    tab.associatedTerminalPaneID = adjacentTerminalID
                }
                return tab
            }
            return group
        }
        var backfilledLayout = normalizedLayout
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

        var keptPrimary = false
        return foldingDocumentGroups(
            in: layout,
            mergedGroup: merged,
            keptPrimary: &keptPrimary
        ) ?? .documentGroup(merged)
    }

    private static func normalizingDocumentGroupIDs(
        in layout: TerminalPaneLayout,
        seenGroupIDs: inout Set<DocumentGroup.ID>
    ) -> TerminalPaneLayout {
        switch layout {
        case .pane:
            return layout
        case let .documentGroup(group):
            guard !seenGroupIDs.insert(group.id).inserted else {
                return layout
            }
            var replacementID = UUID()
            while !seenGroupIDs.insert(replacementID).inserted {
                replacementID = UUID()
            }
            return .documentGroup(
                DocumentGroup(
                    id: replacementID,
                    tabs: group.tabs,
                    selectedTabID: group.selectedTabID
                ))
        case let .split(split):
            return .split(
                TerminalSplit(
                    id: split.id,
                    orientation: split.orientation,
                    first: normalizingDocumentGroupIDs(
                        in: split.first,
                        seenGroupIDs: &seenGroupIDs
                    ),
                    second: normalizingDocumentGroupIDs(
                        in: split.second,
                        seenGroupIDs: &seenGroupIDs
                    ),
                    firstFraction: split.firstFraction
                ))
        }
    }

    private static func foldingDocumentGroups(
        in layout: TerminalPaneLayout,
        mergedGroup: DocumentGroup,
        keptPrimary: inout Bool
    ) -> TerminalPaneLayout? {
        switch layout {
        case .pane:
            return layout
        case .documentGroup:
            guard !keptPrimary else {
                return nil
            }
            keptPrimary = true
            return .documentGroup(mergedGroup)
        case let .split(split):
            let first = foldingDocumentGroups(
                in: split.first,
                mergedGroup: mergedGroup,
                keptPrimary: &keptPrimary
            )
            let second = foldingDocumentGroups(
                in: split.second,
                mergedGroup: mergedGroup,
                keptPrimary: &keptPrimary
            )
            switch (first, second) {
            case let (.some(first), .some(second)):
                return .split(
                    TerminalSplit(
                        id: split.id,
                        orientation: split.orientation,
                        first: first,
                        second: second,
                        firstFraction: split.firstFraction
                    ))
            case let (.some(layout), nil), let (nil, .some(layout)):
                return layout
            case (nil, nil):
                return nil
            }
        }
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
