import AwesoMuxBridgeProtocol
import Foundation
import Testing
@testable import AwesoMuxCore

@Suite struct TerminalSessionNeedsUserInputTests {
    private func session(attention: AttentionReason?) -> TerminalSession {
        var session = TerminalSession(title: "alpha", workingDirectory: "~")
        session.layout = session.layout.mappingPanes { pane in
            var pane = pane
            pane.attentionReason = attention
            return pane
        }
        return session
    }

    @Test func permissionPromptQualifies() {
        #expect(session(attention: .permissionPrompt).needsUserInput)
    }

    @Test func userInputRequiredQualifies() {
        #expect(session(attention: .userInputRequired).needsUserInput)
    }

    @Test func lowerPriorityReasonsDoNot() {
        for reason in [AttentionReason.bell, .desktopNotification, .processError, .unknown] {
            #expect(!session(attention: reason).needsUserInput, "\(reason) must not lift")
        }
    }

    @Test func noAttentionDoesNot() {
        #expect(!session(attention: nil).needsUserInput)
    }

    /// A split whose FIRST pane is calm and whose SECOND pane waits. The
    /// non-allocating tree walk has to recurse into both legs — an
    /// implementation that short-circuits on the first leg's answer instead of
    /// on a `true` reads this session as calm and drops it out of the section.
    private func splitSession(
        first: AttentionReason?,
        second: AttentionReason?
    ) -> TerminalSession {
        var paneA = TerminalPane(title: "a", workingDirectory: "~", executionPlan: .local)
        paneA.attentionReason = first
        var paneB = TerminalPane(title: "b", workingDirectory: "~", executionPlan: .local)
        paneB.attentionReason = second
        return TerminalSession(
            title: "split",
            workingDirectory: "~",
            layout: .split(
                TerminalSplit(orientation: .horizontal, first: .pane(paneA), second: .pane(paneB))
            )
        )
    }

    @Test func waitingSiblingInSecondSplitLegQualifies() {
        #expect(splitSession(first: nil, second: .permissionPrompt).needsUserInput)
    }

    @Test func waitingSiblingInFirstSplitLegQualifies() {
        // The early-exit leg. Paired with the test above so a recursion that
        // only ever visits one side can't pass both.
        #expect(splitSession(first: .userInputRequired, second: nil).needsUserInput)
    }

    @Test func fullyCalmSplitDoesNot() {
        #expect(!splitSession(first: nil, second: nil).needsUserInput)
        // A split that is loud but not *waiting* still must not lift.
        #expect(!splitSession(first: .bell, second: .processError).needsUserInput)
    }

    @Test func isStrictlyNarrowerThanNeedsAcknowledgement() {
        // A bell sets needsAcknowledgement (peach cue) but must not reorder the
        // sidebar. Guards against a refactor quietly collapsing the two.
        let belled = session(attention: .bell)
        #expect(belled.needsAcknowledgement)
        #expect(!belled.needsUserInput)
    }
}
