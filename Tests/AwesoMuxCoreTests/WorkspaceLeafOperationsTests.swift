import Foundation
import Testing
@testable import AwesoMuxCore

@Suite struct WorkspaceLeafOperationsTests {
    private func pane(_ title: String = "zsh") -> TerminalPane {
        TerminalPane(title: title, workingDirectory: "/tmp", executionPlan: .local)
    }

    private func group() -> DocumentGroup {
        let doc = DocumentPane(
            fileURL: URL(fileURLWithPath: NSTemporaryDirectory() + "op-\(UUID().uuidString).md"),
            title: "notes.md"
        )
        return DocumentGroup(tabs: [doc], selectedTabID: doc.id)
    }

    @Test func documentGroupLookupFindsOnlyItsOwnID() {
        let t = pane()
        let g = group()
        let layout = TerminalPaneLayout.split(
            TerminalSplit(
                orientation: .vertical, first: .pane(t), second: .documentGroup(g)
            ))
        #expect(layout.documentGroup(id: g.id) == g)
        // A terminal id must never resolve a document group even by raw UUID.
        #expect(layout.documentGroup(id: t.id) == nil)
    }

}
