import Foundation
import Testing
@testable import AwesoMuxCore

// Pure-function coverage for the v4→v5 layer-2 migration (INT-748): adjacency
// backfill of tab associations plus the fold of per-document single-tab groups
// into one viewer. The `< 5` version gate itself lives in
// `TerminalSession.init(from:)` and is covered by the persistence suite.
@Suite struct DocumentGroupMigrationTests {
    private func makeTab(_ name: String) -> DocumentPane {
        DocumentPane(fileURL: URL(fileURLWithPath: "/tmp/\(name)"), title: name)
    }

    private func singleTabGroup(_ tab: DocumentPane) -> DocumentGroup {
        DocumentGroup(tabs: [tab], selectedTabID: tab.id)
    }

    @Test func layoutWithoutGroupsIsUnchanged() {
        let t1 = TerminalPane(title: "t1", workingDirectory: "/tmp", executionPlan: .local)
        let t2 = TerminalPane(title: "t2", workingDirectory: "/tmp", executionPlan: .local)
        let layout = TerminalPaneLayout.split(TerminalSplit(
            orientation: .vertical, first: .pane(t1), second: .pane(t2)
        ))
        #expect(DocumentGroupMigration.migratingLegacyDocumentLeaves(in: layout) == layout)
    }

    @Test func singleGroupBackfillsAssociationInPlace() throws {
        let terminal = TerminalPane(title: "zsh", workingDirectory: "/tmp", executionPlan: .local)
        let tab = makeTab("a.md")
        let group = singleTabGroup(tab)
        let layout = TerminalPaneLayout.split(TerminalSplit(
            orientation: .vertical,
            first: .pane(terminal),
            second: .documentGroup(group),
            firstFraction: 0.6
        ))

        let migrated = DocumentGroupMigration.migratingLegacyDocumentLeaves(in: layout)

        let migratedGroup = try #require(migrated.firstDocumentGroup)
        #expect(migratedGroup.id == group.id, "the group keeps its identity and position")
        #expect(migratedGroup.tabs.count == 1)
        #expect(
            migratedGroup.tabs[0].associatedTerminalPaneID == terminal.id,
            "nil association backfills from split adjacency"
        )
        // Tree shape is untouched for the single-group case.
        guard case let .split(split) = migrated else {
            Issue.record("expected the terminal|viewer split to survive")
            return
        }
        #expect(split.firstFraction == 0.6)
        #expect(split.first == .pane(terminal))
    }

    @Test func multipleGroupsFoldIntoFirstWithAdjacencyCorrectAssociations() throws {
        // Pre-v5 shape after layer-1 decode: each doc is a single-tab group at
        // its original split position, each beside a DIFFERENT terminal:
        // .split(.split(t1, groupA), .split(t2, groupB))
        let t1 = TerminalPane(title: "t1", workingDirectory: "/tmp", executionPlan: .local)
        let t2 = TerminalPane(title: "t2", workingDirectory: "/tmp", executionPlan: .local)
        let tabA = makeTab("a.md")
        let tabB = makeTab("b.md")
        let groupA = singleTabGroup(tabA)
        let groupB = singleTabGroup(tabB)
        let layout = TerminalPaneLayout.split(TerminalSplit(
            orientation: .horizontal,
            first: .split(TerminalSplit(
                orientation: .vertical, first: .pane(t1), second: .documentGroup(groupA)
            )),
            second: .split(TerminalSplit(
                orientation: .vertical, first: .pane(t2), second: .documentGroup(groupB)
            ))
        ))

        let migrated = DocumentGroupMigration.migratingLegacyDocumentLeaves(in: layout)

        let merged = try #require(migrated.firstDocumentGroup)
        #expect(merged.id == groupA.id, "the first group in tree order keeps its position")
        #expect(merged.tabs.map(\.id) == [tabA.id, tabB.id], "later groups' tabs append in tree order")
        #expect(merged.selectedTabID == tabA.id, "first tab selected for determinism")
        #expect(
            merged.tab(id: tabA.id)?.associatedTerminalPaneID == t1.id,
            "each document keeps the terminal it was actually next to"
        )
        #expect(
            merged.tab(id: tabB.id)?.associatedTerminalPaneID == t2.id,
            "backfill runs BEFORE the fold moves a group away from its split"
        )
        // groupB's leaf collapsed out; both terminals survive.
        #expect(migrated.paneIDs == [t1.id, t2.id])
    }

    @Test func existingAssociationIsNotOverwrittenByBackfill() throws {
        let terminal = TerminalPane(title: "zsh", workingDirectory: "/tmp", executionPlan: .local)
        let recordedID = TerminalPane.ID()
        var tab = makeTab("a.md")
        tab.associatedTerminalPaneID = recordedID
        let layout = TerminalPaneLayout.split(TerminalSplit(
            orientation: .vertical,
            first: .pane(terminal),
            second: .documentGroup(singleTabGroup(tab))
        ))

        let migrated = DocumentGroupMigration.migratingLegacyDocumentLeaves(in: layout)

        let group = try #require(migrated.firstDocumentGroup)
        #expect(
            group.tabs[0].associatedTerminalPaneID == recordedID,
            "a recorded association wins over adjacency, even a dangling one"
        )
    }

    @Test func duplicateGroupIDsKeepDistinctHybridTabsAndAssociations() throws {
        let duplicateID = UUID()
        let firstPane = TerminalPane(title: "first", workingDirectory: "/first", executionPlan: .local)
        let secondPane = TerminalPane(title: "second", workingDirectory: "/second", executionPlan: .local)
        let firstTab = makeTab("first.md")
        let secondTab = makeTab("second.md")
        let layout = TerminalPaneLayout.split(
            TerminalSplit(
                orientation: .horizontal,
                first: .split(
                    TerminalSplit(
                        orientation: .vertical,
                        first: .pane(firstPane),
                        second: .documentGroup(
                            DocumentGroup(
                                id: duplicateID,
                                tabs: [firstTab],
                                selectedTabID: firstTab.id
                            ))
                    )),
                second: .split(
                    TerminalSplit(
                        orientation: .vertical,
                        first: .pane(secondPane),
                        second: .documentGroup(
                            DocumentGroup(
                                id: duplicateID,
                                tabs: [secondTab],
                                selectedTabID: secondTab.id
                            ))
                    ))
            ))

        let migrated = DocumentGroupMigration.migratingLegacyDocumentLeaves(in: layout)
        let group = try #require(migrated.firstDocumentGroup)

        #expect(group.tabs.map(\.id) == [firstTab.id, secondTab.id])
        #expect(group.tabs.map(\.associatedTerminalPaneID) == [firstPane.id, secondPane.id])
    }
}
