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
        let fallbackTerminalID = layout.firstPane?.id
        let backfilledLayout: TerminalPaneLayout
        if case let .documentGroup(group) = layout {
            backfilledLayout = .documentGroup(
                backfillingNilAssociations(in: group, with: fallbackTerminalID)
            )
        } else {
            backfilledLayout =
                backfillingLegacyAssociations(
                    in: layout,
                    fallbackTerminalID: fallbackTerminalID
                ).layout
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

    private static func backfillingLegacyAssociations(
        in layout: TerminalPaneLayout,
        fallbackTerminalID: TerminalPane.ID?
    ) -> (layout: TerminalPaneLayout, firstPaneID: TerminalPane.ID?) {
        switch layout {
        case let .pane(pane):
            return (layout, pane.id)
        case .documentGroup:
            return (layout, nil)
        case let .split(split):
            let first = backfillingLegacyAssociations(
                in: split.first,
                fallbackTerminalID: fallbackTerminalID
            )
            let second = backfillingLegacyAssociations(
                in: split.second,
                fallbackTerminalID: fallbackTerminalID
            )
            let firstLayout: TerminalPaneLayout
            if case let .documentGroup(group) = split.first {
                firstLayout = .documentGroup(
                    backfillingNilAssociations(
                        in: group,
                        with: second.firstPaneID ?? fallbackTerminalID
                    ))
            } else {
                firstLayout = first.layout
            }
            let secondLayout: TerminalPaneLayout
            if case let .documentGroup(group) = split.second {
                secondLayout = .documentGroup(
                    backfillingNilAssociations(
                        in: group,
                        with: first.firstPaneID ?? fallbackTerminalID
                    ))
            } else {
                secondLayout = second.layout
            }
            return (
                .split(
                    TerminalSplit(
                        id: split.id,
                        orientation: split.orientation,
                        first: firstLayout,
                        second: secondLayout,
                        firstFraction: split.firstFraction
                    )),
                first.firstPaneID ?? second.firstPaneID
            )
        }
    }

    private static func backfillingNilAssociations(
        in group: DocumentGroup,
        with terminalID: TerminalPane.ID?
    ) -> DocumentGroup {
        var group = group
        group.tabs = group.tabs.map { tab in
            var tab = tab
            if tab.associatedTerminalPaneID == nil {
                tab.associatedTerminalPaneID = terminalID
            }
            return tab
        }
        return group
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
