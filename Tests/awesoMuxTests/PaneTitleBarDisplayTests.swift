import AwesoMuxCore
import Testing
@testable import awesoMux

@Suite
struct PaneTitleBarDisplayTests {
    @Test
    func usesTitleWhenPresent() {
        let pane = TerminalPane(title: "My Backend", workingDirectory: "~/dev", executionPlan: .local)
        #expect(PaneTitleBarView.displayTitle(for: pane) == "My Backend")
    }

    @Test
    func fallsBackToWorkingDirectoryBasename() {
        let pane = TerminalPane(title: "   ", workingDirectory: "~/Development/awesomux", executionPlan: .local)
        #expect(PaneTitleBarView.displayTitle(for: pane) == "awesomux")
    }

    @Test("declared SSH pane accessibility names its submitted target")
    func declaredSSHAccessibilityNamesSubmittedTarget() {
        let target = RemoteTarget(user: "alice", host: "buildbox-alias")!
        let pane = TerminalPane(
            title: "deploy@resolved.example",
            workingDirectory: "/srv/app",
            remoteHost: "resolved.example",
            executionPlan: .ssh(SSHExecution(target: target))
        )

        #expect(pane.remotePresentationHost == "alice@buildbox-alias")
        #expect(
            PaneTitleBarView.accessibilityLabel(for: pane, title: "deploy@resolved.example")
                == "Pane: deploy@resolved.example, Remote session on alice@buildbox-alias"
        )
    }
}
