import AwesoMuxCore
import Testing
@testable import awesoMux

@Suite("Ghostty surface attention decisions")
struct GhosttySurfaceAttentionTests {
    @Test("visible-text suppression reads this pane's state, not the loudest sibling")
    @MainActor
    func suppressionReadsOwnPaneState() {
        // M4: a sibling pane already in `.needsAttention` makes the session's
        // loudest-pane fold `.needsAttention`. Feeding THAT into visible-text
        // suppression would mask this pane detecting its OWN `.needsAttention`.
        // The suppression input must be this pane's own state.
        let thisPane = TerminalPane(
            title: "codex",
            workingDirectory: "~",
            agentKind: .codex,
            agentExecutionState: .running
        )
        let sibling = TerminalPane(
            title: "claude",
            workingDirectory: "~",
            agentKind: .claudeCode,
            attentionReason: .permissionPrompt
        )
        let session = TerminalSession(
            title: "split",
            workingDirectory: "~",
            layout: .split(TerminalSplit(
                orientation: .vertical,
                first: .pane(thisPane),
                second: .pane(sibling)
            )),
            activePaneID: thisPane.id
        )

        // The loudest-pane fold is the sibling's `.needsAttention`.
        #expect(session.agentState == .needsAttention)
        // The suppression input is THIS pane's own state instead.
        #expect(
            GhosttySurfaceNSView.visibleTextSuppressionLiveState(
                in: session,
                paneID: thisPane.id
            ) == .running
        )
    }

    @Test("selected key workspace suppresses generic output attention")
    func selectedKeyWorkspaceSuppressesGenericOutputAttention() {
        #expect(!GhosttySurfaceNSView.shouldMarkGenericOutputNeedsAttention(
            isKeyWindow: true,
            isSelectedWorkspace: true
        ))
    }

    @Test("generic output attention still marks background workspaces")
    func genericOutputAttentionStillMarksBackgroundWorkspaces() {
        #expect(GhosttySurfaceNSView.shouldMarkGenericOutputNeedsAttention(
            isKeyWindow: true,
            isSelectedWorkspace: false
        ))
        #expect(GhosttySurfaceNSView.shouldMarkGenericOutputNeedsAttention(
            isKeyWindow: false,
            isSelectedWorkspace: true
        ))
    }
}
