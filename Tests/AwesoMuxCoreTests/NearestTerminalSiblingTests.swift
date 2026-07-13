import Foundation
import Testing
@testable import AwesoMuxCore

// Since INT-748, `nearestTerminalSibling(ofDocumentGroup:)` is migration-only:
// live send/stage routing reads each tab's stored `associatedTerminalPaneID`.
// This suite is the contract for the v4→v5 association backfill, which runs
// while each legacy document still sits in its original split position — so
// split adjacency remains exactly the behavior these cases pin down.
@Suite("nearestTerminalSibling (migration backfill)")
struct NearestTerminalSiblingTests {
    private func makeTerminal(_ title: String = "zsh") -> TerminalPane {
        TerminalPane(title: title, workingDirectory: "/tmp", executionPlan: .local)
    }

    private func makeGroup() -> DocumentGroup {
        let doc = DocumentPane(
            fileURL: URL(fileURLWithPath: "/tmp/test-\(UUID().uuidString).md"),
            title: "notes.md"
        )
        return DocumentGroup(tabs: [doc], selectedTabID: doc.id)
    }

    @Test("direct split: group on the right returns the left terminal")
    func directSplitGroupOnRight() {
        let terminal = makeTerminal()
        let group = makeGroup()
        let layout = TerminalPaneLayout.split(TerminalSplit(
            orientation: .vertical,
            first: .pane(terminal),
            second: .documentGroup(group)
        ))
        #expect(layout.nearestTerminalSibling(ofDocumentGroup: group.id) == terminal.id)
    }

    @Test("direct split: group on the left returns the right terminal")
    func directSplitGroupOnLeft() {
        let terminal = makeTerminal()
        let group = makeGroup()
        let layout = TerminalPaneLayout.split(TerminalSplit(
            orientation: .vertical,
            first: .documentGroup(group),
            second: .pane(terminal)
        ))
        #expect(layout.nearestTerminalSibling(ofDocumentGroup: group.id) == terminal.id)
    }

    @Test("nested split: group shares the inner split with its direct sibling terminal")
    func nestedSplitTargetsImmediateSibling() {
        // Layout: .split(.pane(t1), .split(.pane(t2), .documentGroup(group)))
        // The backfill should target t2 (the group's immediate split partner), NOT t1.
        let t1 = makeTerminal("t1")
        let t2 = makeTerminal("t2")
        let group = makeGroup()
        let layout = TerminalPaneLayout.split(TerminalSplit(
            orientation: .vertical,
            first: .pane(t1),
            second: .split(TerminalSplit(
                orientation: .horizontal,
                first: .pane(t2),
                second: .documentGroup(group)
            ))
        ))
        #expect(layout.nearestTerminalSibling(ofDocumentGroup: group.id) == t2.id)
    }

    @Test("unknown group ID returns nil")
    func unknownIDReturnsNil() {
        let terminal = makeTerminal()
        let group = makeGroup()
        let layout = TerminalPaneLayout.split(TerminalSplit(
            orientation: .vertical,
            first: .pane(terminal),
            second: .documentGroup(group)
        ))
        let unknownID = DocumentGroup.ID()
        #expect(layout.nearestTerminalSibling(ofDocumentGroup: unknownID) == nil)
    }

    @Test("deeply nested: sibling is the first terminal in the OTHER branch")
    func deeplyNestedSecondBranchHasNestedTerminals() {
        // Layout: .split(.split(.pane(t1), .pane(t2)), .split(.pane(t3), .documentGroup(g)))
        // The group's immediate split is .split(.pane(t3), .documentGroup(g)); sibling = t3.
        let t1 = makeTerminal("t1")
        let t2 = makeTerminal("t2")
        let t3 = makeTerminal("t3")
        let group = makeGroup()
        let layout = TerminalPaneLayout.split(TerminalSplit(
            orientation: .horizontal,
            first: .split(TerminalSplit(
                orientation: .vertical,
                first: .pane(t1),
                second: .pane(t2)
            )),
            second: .split(TerminalSplit(
                orientation: .vertical,
                first: .pane(t3),
                second: .documentGroup(group)
            ))
        ))
        #expect(layout.nearestTerminalSibling(ofDocumentGroup: group.id) == t3.id)
    }
}
