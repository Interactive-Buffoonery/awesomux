import AwesoMuxBridgeProtocol
import AwesoMuxCore
import Foundation
import Testing
@testable import awesoMux

// Isolation is needed because a live clipboard/terminal journey cannot reliably
// arrange stale associations, unreadable foreground probes, and busy agents.
@MainActor
@Suite("Document Codex copy applicability")
struct DocumentCodexCopyTests {
    @Test("Codex copy works without a waiting stamp", arguments: [AgentState.thinking, .waiting, .needsAttention, .idle])
    func codexCopy(state: AgentState) {
        let (layout, document, terminal) = fixture(kind: .codex, state: state)
        #expect(resolve(layout, document) == .available(terminal))
        #expect(DocumentPaneSendBar.sendButtonTitle(for: .available(terminal)) == "Copy for Codex")
    }

    @Test("Claude still needs trusted waiting evidence")
    func claudeStillGated() {
        let (layout, document, _) = fixture(kind: .claudeCode, state: .waiting)
        #expect(resolve(layout, document) == .unavailable(.noVerifiedAgent))
    }

    @Test("Copy refuses manual SSH and unreadable local foreground")
    func copyLocality() {
        let (layout, document, _) = fixture(kind: .codex, state: .thinking)
        #expect(resolve(layout, document, comm: "ssh") == .unavailable(.foregroundSSH))
        #expect(resolve(layout, document, comm: nil) == .unavailable(.localTerminalUnverified))
    }

    @Test("A stale document association does not select another terminal")
    func staleAssociation() {
        let (layout, document, _) = fixture(kind: .codex, state: .waiting, stale: true)
        #expect(resolve(layout, document) == .unavailable(.terminalUnavailable))
    }

    @Test("A stale Codex identity never offers copy over a shell or remote wrapper", arguments: ["zsh", "vim", "mosh-client", "tmux"])
    func staleCodexForeground(comm: String) {
        let (layout, document, _) = fixture(kind: .codex, state: .waiting)
        #expect(resolve(layout, document, comm: comm) == .unavailable(.noVerifiedAgent))
    }

    @Test("Verified waiting Claude remains available")
    func verifiedClaude() {
        let (layout, document, terminal) = fixture(kind: .claudeCode, state: .waiting)
        let generation = AgentForegroundIncarnation(pid: 123, startedAt: 456)
        #expect(
            DocumentPaneSendBar.resolveHandoffTarget(
                in: layout, for: document.id,
                isIntegrationEnabled: { _ in true }, foregroundComm: { _ in "claude" },
                foregroundGeneration: { _ in generation }, verifiedWaitingForegroundGeneration: { _ in generation }) == .available(terminal)
        )
    }

    private func resolve(_ layout: TerminalPaneLayout, _ document: DocumentPane, comm: String? = "codex") -> DocumentNudgeTargetResolution {
        DocumentPaneSendBar.resolveHandoffTarget(
            in: layout, for: document.id, isIntegrationEnabled: { _ in true }, foregroundComm: { _ in comm })
    }

    private func fixture(kind: AgentKind, state: AgentState, stale: Bool = false) -> (TerminalPaneLayout, DocumentPane, TerminalPane) {
        let terminal = TerminalPane(title: "agent", workingDirectory: "/tmp", agentKind: kind, agentState: state, executionPlan: .local)
        let document = DocumentPane(
            fileURL: URL(fileURLWithPath: "/tmp/review.md"), title: "review.md", associatedTerminalPaneID: stale ? UUID() : terminal.id)
        let group = DocumentGroup(tabs: [document], selectedTabID: document.id)
        let layout = TerminalPaneLayout.split(TerminalSplit(orientation: .vertical, first: .pane(terminal), second: .documentGroup(group)))
        return (layout, document, terminal)
    }
}
