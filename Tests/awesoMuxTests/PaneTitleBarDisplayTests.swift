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
}
