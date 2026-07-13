import AwesoMuxCore
import Foundation
import Testing
@testable import AwesoMuxTestSupport

@Suite("Test data")
struct TestDataTests {
    @Test("pane uses useful defaults and explicit overrides")
    func paneDefaultsAndOverrides() {
        let id = UUID()
        let pane = TestData.pane(
            id: id,
            title: "Logs",
            workingDirectory: "/repo",
            agentKind: .codex,
            agentExecutionState: .thinking
        )

        #expect(pane.id == id)
        #expect(pane.title == "Logs")
        #expect(pane.workingDirectory == "/repo")
        #expect(pane.agentKind == .codex)
        #expect(pane.agentExecutionState == .thinking)
        #expect(pane.executionPlan == .local)
    }

    @Test("session builds a real layout and honors the active pane")
    func sessionDefaultsAndOverrides() {
        let pane = TestData.pane(title: "Shell", workingDirectory: "/repo")
        let session = TestData.session(
            title: "Project",
            workingDirectory: "/repo",
            notificationsMuted: true,
            layout: .pane(pane),
            activePaneID: pane.id
        )

        #expect(session.title == "Project")
        #expect(session.notificationsMuted)
        #expect(session.activePaneID == pane.id)
        #expect(session.activePane?.workingDirectory == "/repo")
    }

    @Test("workspace supplies a session and accepts group overrides")
    func workspaceDefaultsAndOverrides() {
        let session = TestData.session(title: "Project")
        let workspace = TestData.workspace(name: "Code", color: .mauve, sessions: [session])

        #expect(workspace.name == "Code")
        #expect(workspace.color == .mauve)
        #expect(workspace.sessions == [session])
    }
}
