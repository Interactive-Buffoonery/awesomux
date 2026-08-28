import AwesoMuxCore
import Foundation
import Testing
@testable import awesoMux

@MainActor
@Suite("Process-exit workspace-close announcements")
struct GhosttySurfaceProcessExitAnnouncementTests {
    @Test("clean process exit closes the workspace and announces it")
    func cleanExitAnnouncesWorkspaceClose() {
        let fixture = makeFixture()
        var exitedWithError: Bool?
        var removedAtAnnouncement: Bool?
        fixture.view.announceWorkspaceClosedAfterProcessExit = {
            [store = fixture.store, sessionID = fixture.sessionID] in
            exitedWithError = $0
            removedAtAnnouncement = store.session(id: sessionID) == nil
        }

        fixture.view.closeAfterProcessExit(processAlive: false)

        #expect(removedAtAnnouncement == true)
        #expect(exitedWithError == false)
    }

    @Test("error process exit closes the workspace and announces the error")
    func errorExitAnnouncesWorkspaceClose() {
        let fixture = makeFixture()
        var exitedWithError: Bool?
        var removedAtAnnouncement: Bool?
        fixture.view.announceWorkspaceClosedAfterProcessExit = {
            [store = fixture.store, sessionID = fixture.sessionID] in
            exitedWithError = $0
            removedAtAnnouncement = store.session(id: sessionID) == nil
        }
        fixture.view.commandExitCache.record(
            exitCode: 1,
            at: Date().timeIntervalSinceReferenceDate
        )

        fixture.view.closeAfterProcessExit(processAlive: false)

        #expect(removedAtAnnouncement == true)
        #expect(exitedWithError == true)
    }

    private func makeFixture() -> (
        view: GhosttySurfaceNSView,
        store: SessionStore,
        sessionID: TerminalSession.ID
    ) {
        let pane = TerminalPane(
            title: "shell",
            workingDirectory: "/tmp",
            executionPlan: .local
        )
        let session = TerminalSession(
            title: "workspace",
            workingDirectory: "/tmp",
            layout: .pane(pane),
            activePaneID: pane.id
        )
        let store = SessionStore(
            groups: [SessionGroup(name: "awesoMux", sessions: [session])],
            selectedSessionID: session.id
        )
        let runtime = GhosttyRuntime(initialCommandBridgeEnabled: false)
        let view = runtime.surfaceView(
            sessionStore: store,
            session: session,
            pane: pane,
            enabledAgentRuntimeFileDropSources: [],
            grokIconEnabled: false
        )
        return (view, store, session.id)
    }
}
