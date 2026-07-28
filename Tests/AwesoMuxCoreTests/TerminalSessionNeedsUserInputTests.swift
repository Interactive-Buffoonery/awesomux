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

    @Test func isStrictlyNarrowerThanNeedsAcknowledgement() {
        // A bell sets needsAcknowledgement (peach cue) but must not reorder the
        // sidebar. Guards against a refactor quietly collapsing the two.
        let belled = session(attention: .bell)
        #expect(belled.needsAcknowledgement)
        #expect(!belled.needsUserInput)
    }
}
