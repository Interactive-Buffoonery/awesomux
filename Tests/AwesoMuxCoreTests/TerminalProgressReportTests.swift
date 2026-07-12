import Foundation
import Testing
@testable import AwesoMuxCore

@MainActor
@Suite("Terminal progress reports")
struct TerminalProgressReportTests {
    @Test("fresh panes have no progress report")
    func freshPanesHaveNoProgressReport() {
        let pane = TerminalPane(title: "shell", workingDirectory: "~")

        #expect(pane.progressReport == nil)
    }

    @Test("progress reports are runtime-only pane state")
    func progressReportsAreRuntimeOnlyPaneState() throws {
        let pane = TerminalPane(
            title: "build",
            workingDirectory: "~",
            progressReport: TerminalProgressReport(state: .set, progress: 50)
        )

        let data = try JSONEncoder().encode(pane)
        let decoded = try JSONDecoder().decode(TerminalPane.self, from: data)

        #expect(decoded.progressReport == nil)
    }

    @Test("session store applies and clears progress reports")
    func sessionStoreAppliesAndClearsProgressReports() {
        let (store, session, paneID) = makeStore()

        store.updatePane(
            sessionID: session.id,
            paneID: paneID,
            progressReport: TerminalProgressReport(state: .set, progress: 50)
        )

        #expect(store.session(id: session.id)?.layout.pane(id: paneID)?.progressReport
            == TerminalProgressReport(state: .set, progress: 50))

        store.updatePane(
            sessionID: session.id,
            paneID: paneID,
            progressReport: TerminalProgressReport(state: .remove)
        )

        #expect(store.session(id: session.id)?.layout.pane(id: paneID)?.progressReport == nil)
    }

    @Test("progress report survives active pane focus changes")
    func progressReportSurvivesFocusChange() throws {
        let first = TerminalPane(title: "first", workingDirectory: "/a")
        let second = TerminalPane(title: "second", workingDirectory: "/b")
        let session = TerminalSession(
            title: "workspace",
            workingDirectory: "/a",
            layout: .split(TerminalSplit(
                orientation: .vertical,
                first: .pane(first),
                second: .pane(second)
            )),
            activePaneID: first.id
        )
        let store = SessionStore(
            groups: [SessionGroup(name: "main", sessions: [session])],
            selectedSessionID: session.id
        )
        let report = TerminalProgressReport(state: .set, progress: 25)

        store.updatePane(sessionID: session.id, paneID: first.id, progressReport: report)
        #expect(store.focusPane(at: 2, in: session.id))

        let updated = try #require(store.session(id: session.id))
        #expect(updated.activePaneID == second.id)
        #expect(updated.layout.pane(id: first.id)?.progressReport == report)
        #expect(updated.layout.pane(id: second.id)?.progressReport == nil)
    }

    @Test("early progress reports for missing sessions or panes are safe no-ops")
    func earlyProgressReportsForMissingTargetsAreSafeNoops() {
        let (store, session, paneID) = makeStore()
        let before = store.groups
        let report = TerminalProgressReport(state: .indeterminate)

        store.updatePane(sessionID: UUID(), paneID: paneID, progressReport: report)
        store.updatePane(sessionID: session.id, paneID: UUID(), progressReport: report)

        #expect(store.groups == before)
        #expect(store.session(id: session.id)?.layout.pane(id: paneID)?.progressReport == nil)
    }

    @Test("progress values clamp to OSC percent bounds")
    func progressValuesClampToOSCPercentBounds() {
        #expect(TerminalProgressReport(state: .set, progress: 127).progress == 100)
        #expect(TerminalProgressReport(state: .indeterminate, progress: 50).progress == nil)
        #expect(TerminalProgressReport(state: .remove, progress: 50).progress == nil)
    }

    private func makeStore() -> (
        store: SessionStore,
        session: TerminalSession,
        paneID: TerminalPane.ID
    ) {
        let session = TerminalSession(
            title: "shell",
            workingDirectory: "~",
            agentKind: .shell,
            agentState: .idle
        )
        let store = SessionStore(
            groups: [SessionGroup(name: "main", sessions: [session])],
            selectedSessionID: session.id
        )

        return (store, session, session.activePaneID)
    }
}
