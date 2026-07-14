import AwesoMuxCore
import Testing
@testable import awesoMux

@Suite("Session group execution presentation")
struct SessionGroupExecutionPresentationTests {
    private let alpha = RemoteTarget(user: "alice", host: "alpha")!
    private let zeta = RemoteTarget(user: "zoe", host: "zeta")!

    @Test("wide and VoiceOver copy distinguish active work from defaults")
    func activeWorkAndDefaults() {
        let local = SessionGroupExecutionPresentation(
            summary: SessionGroupExecutionSummary(sessions: [])
        )
        let emptyDefault = SessionGroupExecutionPresentation(
            summary: SessionGroupExecutionSummary(sessions: [], defaultTarget: alpha)
        )
        let staleDefault = SessionGroupExecutionPresentation(
            summary: SessionGroupExecutionSummary(
                sessions: [TerminalSession(title: "local", workingDirectory: "~")],
                defaultTarget: alpha
            )
        )

        #expect(local.visibleText == nil)
        #expect(local.accessibilityText == "Local creation default")
        #expect(emptyDefault.visibleText == "SSH default · alice@alpha")
        #expect(emptyDefault.accessibilityText == "SSH creation default alice@alpha, no active remote panes")
        #expect(staleDefault.visibleText == "Local · SSH default alice@alpha")
        #expect(staleDefault.accessibilityText == "Local panes, SSH creation default alice@alpha")
    }

    @Test("one remote target is named and mixed locations stay explicit")
    func activeRemoteLocations() {
        let remote = TerminalSession(
            title: "remote",
            workingDirectory: "~",
            executionPlan: .ssh(SSHExecution(target: alpha))
        )
        let other = TerminalSession(
            title: "other",
            workingDirectory: "~",
            executionPlan: .ssh(SSHExecution(target: zeta))
        )
        let one = SessionGroupExecutionPresentation(
            summary: SessionGroupExecutionSummary(sessions: [remote])
        )
        let mixed = SessionGroupExecutionPresentation(
            summary: SessionGroupExecutionSummary(sessions: [remote, other])
        )

        #expect(one.visibleText == "SSH · alice@alpha")
        #expect(one.accessibilityText == "Remote panes on alice@alpha")
        #expect(mixed.visibleText == "Mixed locations")
        #expect(mixed.accessibilityText == "Remote panes on alice@alpha and zoe@zeta")
    }
}
