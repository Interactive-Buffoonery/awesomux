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

    @Test("rename focus retries through a real edge when focus state is stale")
    func staleRenameFocusUsesASuppressedFalseToTrueEdge() {
        let request = PaneTitleBarView.renameFocusRequest(isCurrentlyFocused: true)

        #expect(request.suppressesBlurCommit)
        #expect(!request.immediateFocus)
        #expect(request.deferredFocus)
    }

    @Test("rename focus does not suppress a blur when focus state is fresh")
    func freshRenameFocusDoesNotSuppressBlur() {
        let request = PaneTitleBarView.renameFocusRequest(isCurrentlyFocused: false)

        #expect(!request.suppressesBlurCommit)
        #expect(!request.immediateFocus)
        #expect(request.deferredFocus)
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
                == "Remote pane on alice@buildbox-alias: deploy@resolved.example"
        )
    }
}
