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

    // MARK: - Tagged identity

    @Test func leafIDsCarryTheKindTag() {
        let t = pane()
        let g = group()
        let layout = TerminalPaneLayout.split(
            TerminalSplit(
                orientation: .vertical, first: .pane(t), second: .documentGroup(g)
            ))
        #expect(layout.leafIDs == [.terminal(t.id), .documentGroup(g.id)])
    }

    @Test func lookupHonorsTheKindTag() {
        let t = pane()
        let g = group()
        let layout = TerminalPaneLayout.split(
            TerminalSplit(
                orientation: .vertical, first: .pane(t), second: .documentGroup(g)
            ))
        #expect(layout.leaf(.terminal(t.id)) == .terminal(t))
        #expect(layout.leaf(.documentGroup(g.id)) == .documentGroup(g))
        // A terminal id must never resolve a document group even by raw UUID.
        #expect(layout.leaf(.documentGroup(t.id)) == nil)
        #expect(layout.leaf(.terminal(g.id)) == nil)
    }

    // MARK: - removingLeaf preserves the distinct per-kind policies

    @Test func removingSoleTerminalClosesWorkspace() {
        let t = pane()
        let layout = TerminalPaneLayout.split(
            TerminalSplit(
                orientation: .vertical, first: .pane(t), second: .documentGroup(group())
            ))
        // Auxiliary leaf can never be the sole survivor -> close the workspace.
        #expect(layout.removingLeaf(.terminal(t.id)) == .closesWorkspace)
    }

    @Test func removingOneOfTwoTerminalsKeepsTheOther() {
        let a = pane("a")
        let b = pane("b")
        let layout = TerminalPaneLayout.split(
            TerminalSplit(
                orientation: .vertical, first: .pane(a), second: .pane(b)
            ))
        guard case let .removed(result) = layout.removingLeaf(.terminal(a.id)) else {
            Issue.record("expected .removed")
            return
        }
        #expect(result.paneIDs == [b.id])
    }

    @Test func removingDocumentGroupCollapsesViewerBackToTerminal() {
        let t = pane()
        let g = group()
        let layout = TerminalPaneLayout.split(
            TerminalSplit(
                orientation: .vertical, first: .pane(t), second: .documentGroup(g)
            ))
        #expect(layout.removingLeaf(.documentGroup(g.id)) == .removed(.pane(t)))
    }

    @Test func removingMissingIdIsNotFoundNeverAStrayClose() {
        let t = pane()
        let g = group()
        let layout = TerminalPaneLayout.split(
            TerminalSplit(
                orientation: .vertical, first: .pane(t), second: .documentGroup(g)
            ))
        // A stale document-group id must NOT be read as "close the workspace".
        #expect(layout.removingLeaf(.documentGroup(DocumentGroup.ID())) == .notFound)
        #expect(layout.removingLeaf(.terminal(TerminalPane.ID())) == .notFound)
    }

    @Test func removingPresentRootDocumentGroupClosesWorkspaceNotNotFound() {
        // A terminal-free root is structurally invalid as a session but a
        // constructible TerminalPaneLayout; removing the present-and-only group
        // must report .closesWorkspace, never .notFound for a present id.
        let g = group()
        let layout = TerminalPaneLayout.documentGroup(g)
        #expect(layout.removingLeaf(.documentGroup(g.id)) == .closesWorkspace)
    }

    // MARK: - replacingLeaf rejects cross-kind

    @Test func replacingSameKindSucceeds() {
        let t = pane()
        let layout = TerminalPaneLayout.pane(t)
        var renamed = t
        renamed.title = "renamed"
        let result = layout.replacingLeaf(.terminal(t.id), with: .terminal(renamed))
        #expect(result?.pane(id: t.id)?.title == "renamed")
    }

    @Test func replacingCrossKindIsRejected() {
        let t = pane()
        let layout = TerminalPaneLayout.pane(t)
        #expect(layout.replacingLeaf(.terminal(t.id), with: .documentGroup(group())) == nil)
    }

    // MARK: - Descriptor / restoration / close consequence

    @Test func descriptorLabelsEachKind() {
        let t = pane("build")
        let doc = DocumentPane(
            fileURL: URL(fileURLWithPath: NSTemporaryDirectory() + "d-\(UUID().uuidString).md"),
            title: "readme.md"
        )
        let g = DocumentGroup(tabs: [doc], selectedTabID: doc.id)
        #expect(WorkspaceLeaf.terminal(t).descriptor.label == "build")
        #expect(WorkspaceLeaf.documentGroup(g).descriptor.label == "readme.md")
    }

    @Test func labelFallsBackWhenSelectedTabOrphaned() {
        let a = DocumentPane(
            fileURL: URL(fileURLWithPath: NSTemporaryDirectory() + "a-\(UUID().uuidString).md"),
            title: "a.md"
        )
        let b = DocumentPane(
            fileURL: URL(fileURLWithPath: NSTemporaryDirectory() + "b-\(UUID().uuidString).md"),
            title: "b.md"
        )
        var g = DocumentGroup(tabs: [a, b], selectedTabID: b.id)
        g.tabs = [a]  // orphan selectedTabID (b removed); selectedTab is now nil
        #expect(WorkspaceLeaf.documentGroup(g).label == "a.md")
    }

    @Test func restorationRequirementSeparatesReattachFromReopen() {
        let t = pane()
        #expect(WorkspaceLeaf.terminal(t).restorationRequirement == .reattachTerminal(t.terminalSessionID))
        #expect(WorkspaceLeaf.documentGroup(group()).restorationRequirement == .reopenDocumentGroup)
    }

    @Test func closeConsequenceIsImmediateForDocumentsRiskForTerminals() {
        let t = pane()
        let g = group()
        if case .terminalRisk = WorkspaceLeaf.terminal(t).closeConsequence() {
            // ok — terminal routes through the risk policy
        } else {
            Issue.record("terminal close should route through the risk policy")
        }
        #expect(WorkspaceLeaf.documentGroup(g).closeConsequence() == .immediate)
    }

    @Test func workspaceAggregatesLeafCloseConsequences() {
        let layout = TerminalPaneLayout.split(
            TerminalSplit(
                orientation: .vertical, first: .pane(pane()), second: .documentGroup(group())
            ))
        let consequences = layout.closeConsequences()
        #expect(consequences.count == 2)
        #expect(consequences.contains(.immediate))
    }
}
