import AwesoMuxCore
import Testing
@testable import awesoMux

@Suite("Session group remote close presentation")
struct SessionGroupRemoteClosePresentationTests {
    private let target = RemoteTarget(user: "alice", host: "alpha")!

    @Test("local-only groups have no remote close impact")
    func localOnly() {
        let presentation = SessionGroupRemoteClosePresentation(
            summary: SessionGroupExecutionSummary(
                sessions: [TerminalSession(title: "local", workingDirectory: "~")]
            ),
            isEmpty: false
        )

        #expect(!presentation.requiresConfirmation)
        #expect(presentation.lossText == nil)
    }

    @Test("default-only impact never claims active remote work")
    func defaultOnly() {
        let empty = SessionGroupRemoteClosePresentation(
            summary: SessionGroupExecutionSummary(sessions: [], defaultTarget: target),
            isEmpty: true
        )
        let local = SessionGroupRemoteClosePresentation(
            summary: SessionGroupExecutionSummary(
                sessions: [TerminalSession(title: "local", workingDirectory: "~")],
                defaultTarget: target
            ),
            isEmpty: false
        )

        #expect(empty.requiresConfirmation)
        #expect(empty.lossText == "Removing this group removes its SSH creation default alice@alpha. No active remote panes are affected.")
        #expect(local.requiresConfirmation)
        #expect(local.lossText == "Closing this group removes its SSH creation default alice@alpha. Its panes are local.")
    }

    @Test("moved remote panes trigger confirmation without a remote group default")
    func activeRemoteWithoutDefault() {
        let remote = TerminalSession(
            title: "remote",
            workingDirectory: "~",
            executionPlan: .ssh(SSHExecution(target: target))
        )
        let presentation = SessionGroupRemoteClosePresentation(
            summary: SessionGroupExecutionSummary(sessions: [remote]),
            isEmpty: false
        )

        #expect(presentation.requiresConfirmation)
        #expect(presentation.lossText == "Closing this group terminates remote panes on alice@alpha.")
    }
}
