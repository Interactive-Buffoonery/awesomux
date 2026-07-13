import AwesoMuxCore
import Testing
@testable import awesoMux

@Suite("Surface retain set")
struct SurfaceRetainSetTests {
    @Test("includes main session pane IDs and all auxiliary pane IDs")
    func includesMainSessionAndAuxiliaryPaneIDs() {
        let mainFirst = TerminalPane(title: "main 1", workingDirectory: "/tmp/main-1", executionPlan: .local)
        let mainSecond = TerminalPane(title: "main 2", workingDirectory: "/tmp/main-2", executionPlan: .local)
        let secondary = TerminalPane(title: "secondary", workingDirectory: "/tmp/secondary", executionPlan: .local)
        let tertiary = TerminalPane(title: "tertiary", workingDirectory: "/tmp/tertiary", executionPlan: .local)
        let floating = TerminalPane.ID()
        let mainSession = TerminalSession(
            title: "main",
            workingDirectory: "/tmp/main-1",
            layout: .split(TerminalSplit(
                orientation: .vertical,
                first: .pane(mainFirst),
                second: .pane(mainSecond)
            )),
            activePaneID: mainFirst.id
        )
        let secondarySession = TerminalSession(
            title: "secondary",
            workingDirectory: secondary.workingDirectory,
            layout: .pane(secondary),
            activePaneID: secondary.id
        )
        let tertiarySession = TerminalSession(
            title: "tertiary",
            workingDirectory: tertiary.workingDirectory,
            layout: .pane(tertiary),
            activePaneID: tertiary.id
        )

        let retainedPaneIDs = SurfaceRetainSet.paneIDs(
            mainGroups: [
                SessionGroup(name: "Main", sessions: [mainSession, secondarySession]),
                SessionGroup(name: "Aux", sessions: [tertiarySession])
            ],
            auxiliaryPaneIDs: [floating, secondary.id]
        )

        #expect(retainedPaneIDs == Set([
            mainFirst.id,
            mainSecond.id,
            secondary.id,
            tertiary.id,
            floating
        ]))
    }
}
