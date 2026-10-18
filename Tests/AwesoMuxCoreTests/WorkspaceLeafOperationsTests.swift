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

    private enum Removal: CaseIterable { case soleTerminal, oneOfTwo, documentSibling, missingDocument, missingTerminal, rootDocument }

    @Test(arguments: Removal.allCases)
    private func removingLeaf(scenario: Removal) {
        let a = pane("a")
        let b = pane("b")
        let g = group()
        let mixed = TerminalPaneLayout.split(TerminalSplit(orientation: .vertical, first: .pane(a), second: .documentGroup(g)))
        let pair = TerminalPaneLayout.split(TerminalSplit(orientation: .vertical, first: .pane(a), second: .pane(b)))
        switch scenario {
        case .soleTerminal: #expect(mixed.removingLeaf(.terminal(a.id)) == .closesWorkspace)
        case .oneOfTwo: #expect(pair.removingLeaf(.terminal(a.id)) == .removed(.pane(b)))
        case .documentSibling: #expect(mixed.removingLeaf(.documentGroup(g.id)) == .removed(.pane(a)))
        case .missingDocument: #expect(mixed.removingLeaf(.documentGroup(DocumentGroup.ID())) == .notFound)
        case .missingTerminal: #expect(mixed.removingLeaf(.terminal(TerminalPane.ID())) == .notFound)
        case .rootDocument: #expect(TerminalPaneLayout.documentGroup(g).removingLeaf(.documentGroup(g.id)) == .closesWorkspace)
        }
    }

}
