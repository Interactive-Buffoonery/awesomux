import AwesoMuxCore
import Testing

@testable import awesoMux

@MainActor
@Suite("Terminal pane live-title resolution")
struct TerminalPaneLiveTitleResolverTests {
    @Test("the live channel wins over a stale pane value")
    func liveChannelWinsOverStalePane() {
        let fixture = makeFixture()
        let box = fixture.store.liveTitleBox(for: fixture.sessionID)

        fixture.store.updatePane(
            sessionID: fixture.sessionID,
            paneID: fixture.pane.id,
            title: "cargo test"
        )
        fixture.store.updatePane(
            sessionID: fixture.sessionID,
            paneID: fixture.siblingPane.id,
            title: "tail -f server.log"
        )

        #expect(TerminalPaneLiveTitleResolver.title(for: fixture.pane, from: box) == "cargo test")
        #expect(
            TerminalPaneLiveTitleResolver.title(for: fixture.siblingPane, from: box)
                == "tail -f server.log"
        )
    }

    @Test("a missing live channel falls back to the pane value")
    func missingLiveChannelFallsBackToPane() {
        let fixture = makeFixture()
        let unseededBox = fixture.store.liveTitleBox(for: TerminalSession.ID())

        #expect(TerminalPaneLiveTitleResolver.title(for: fixture.pane, from: unseededBox) == "shell")
    }

    private func makeFixture() -> Fixture {
        let pane = TerminalPane(title: "shell", workingDirectory: "~", executionPlan: .local)
        let siblingPane = TerminalPane(title: "logs", workingDirectory: "~", executionPlan: .local)
        let session = TerminalSession(
            title: "workspace",
            workingDirectory: "~",
            layout: .split(
                TerminalSplit(
                    orientation: .vertical,
                    first: .pane(pane),
                    second: .pane(siblingPane)
                )
            ),
            activePaneID: pane.id
        )
        return Fixture(
            store: SessionStore(groups: [SessionGroup(name: "main", sessions: [session])]),
            sessionID: session.id,
            pane: pane,
            siblingPane: siblingPane
        )
    }

    private struct Fixture {
        let store: SessionStore
        let sessionID: TerminalSession.ID
        let pane: TerminalPane
        let siblingPane: TerminalPane
    }
}
