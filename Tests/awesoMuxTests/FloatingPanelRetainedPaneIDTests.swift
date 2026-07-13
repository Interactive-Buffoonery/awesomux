import AwesoMuxCore
import Testing
@testable import awesoMux

@MainActor
@Suite("Floating panel retained pane IDs")
struct FloatingPanelRetainedPaneIDTests {
    @Test("unions every pane ID across floating stores groups sessions and splits")
    func unionsEveryPaneIDAcrossFloatingStoresGroupsSessionsAndSplits() {
        let firstStoreSplit = makeSplitSession(title: "store one split")
        let firstStoreSingle = makeSingleSession(title: "store one single")
        let secondStoreNestedSplit = makeNestedSplitSession(title: "store two nested")
        let secondStoreSingle = makeSingleSession(title: "store two single")
        let firstStore = SessionStore(groups: [
            SessionGroup(name: "Agents", sessions: [
                firstStoreSplit.session,
                firstStoreSingle.session
            ])
        ])
        let secondStore = SessionStore(groups: [
            SessionGroup(name: "Builds", sessions: [
                secondStoreNestedSplit.session
            ]),
            SessionGroup(name: "Shells", sessions: [
                secondStoreSingle.session
            ])
        ])
        let controller = TerminalPanelController(mode: .floating)
        controller.seedRetainedPaneIDTestSlots([
            (workspaceID: TerminalSession.ID(), store: firstStore),
            (workspaceID: TerminalSession.ID(), store: secondStore)
        ])

        #expect(controller.retainedPaneIDs == Set(
            firstStoreSplit.paneIDs
                + firstStoreSingle.paneIDs
                + secondStoreNestedSplit.paneIDs
                + secondStoreSingle.paneIDs
        ))
    }

    private func makeSingleSession(title: String) -> SessionFixture {
        let pane = TerminalPane(title: "\(title) pane", workingDirectory: "/tmp/\(title)", executionPlan: .local)
        let session = TerminalSession(
            title: title,
            workingDirectory: pane.workingDirectory,
            layout: .pane(pane),
            activePaneID: pane.id
        )
        return SessionFixture(session: session, paneIDs: [pane.id])
    }

    private func makeSplitSession(title: String) -> SessionFixture {
        let first = TerminalPane(title: "\(title) first", workingDirectory: "/tmp/\(title)-1", executionPlan: .local)
        let second = TerminalPane(title: "\(title) second", workingDirectory: "/tmp/\(title)-2", executionPlan: .local)
        let session = TerminalSession(
            title: title,
            workingDirectory: first.workingDirectory,
            layout: .split(TerminalSplit(
                orientation: .vertical,
                first: .pane(first),
                second: .pane(second)
            )),
            activePaneID: first.id
        )
        return SessionFixture(session: session, paneIDs: [first.id, second.id])
    }

    private func makeNestedSplitSession(title: String) -> SessionFixture {
        let first = TerminalPane(title: "\(title) first", workingDirectory: "/tmp/\(title)-1", executionPlan: .local)
        let second = TerminalPane(title: "\(title) second", workingDirectory: "/tmp/\(title)-2", executionPlan: .local)
        let third = TerminalPane(title: "\(title) third", workingDirectory: "/tmp/\(title)-3", executionPlan: .local)
        let session = TerminalSession(
            title: title,
            workingDirectory: first.workingDirectory,
            layout: .split(TerminalSplit(
                orientation: .horizontal,
                first: .pane(first),
                second: .split(TerminalSplit(
                    orientation: .vertical,
                    first: .pane(second),
                    second: .pane(third)
                ))
            )),
            activePaneID: first.id
        )
        return SessionFixture(session: session, paneIDs: [first.id, second.id, third.id])
    }

    private struct SessionFixture {
        let session: TerminalSession
        let paneIDs: [TerminalPane.ID]
    }
}
