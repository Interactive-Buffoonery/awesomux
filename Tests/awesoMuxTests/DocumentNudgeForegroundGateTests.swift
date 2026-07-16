import AwesoMuxCore
import Foundation
import Testing
@testable import awesoMux

@MainActor
@Suite("Document nudge foreground gate")
struct DocumentNudgeForegroundGateTests {
    @Test("declared local pane rejects foreground SSH")
    func rejectsForegroundSSH() {
        let fixture = makeFixture(executionPlan: .local)

        #expect(resolve(fixture, returning: .matching) == .unavailable(.foregroundSSH))
    }

    @Test("declared local pane rejects unknown foreground evidence")
    func rejectsUnknownForeground() {
        let fixture = makeFixture(executionPlan: .local)

        #expect(
            resolve(fixture, returning: .unknown) == .unavailable(.localTerminalUnverified)
        )
    }

    @Test("declared local pane becomes eligible on the next safe foreground check")
    func rechecksForegroundEvidence() {
        let fixture = makeFixture(executionPlan: .local)

        #expect(resolve(fixture, returning: .matching) == .unavailable(.foregroundSSH))
        #expect(resolve(fixture, returning: .notMatching) == .available(fixture.terminal))
    }

    @Test("declared remote pane is rejected without consulting local process evidence")
    func declaredRemoteShortCircuitsProbe() {
        let target = RemoteTarget(user: "alice", host: "remote.example")!
        let fixture = makeFixture(executionPlan: .ssh(SSHExecution(target: target)))

        let resolution = DocumentPaneSendBar.resolveNudgeTarget(
            in: fixture.layout,
            for: fixture.document.id
        ) { _, _ in
            Issue.record("declared remote panes must not consult local process evidence")
            return .notMatching
        }

        #expect(resolution == .unavailable(.requiresLocalTerminal))
    }

    @Test("command-finished shell activity invalidates a disabled send bar")
    func commandFinishedInvalidatesSendBar() {
        let fixture = makeFixture(executionPlan: .local, shellActivity: .busy)
        let store = SessionStore(groups: [
            SessionGroup(name: "main", sessions: [fixture.session])
        ])
        let busyID = DocumentNudgeSendBarID(
            documentID: fixture.document.id,
            shellActivity: .busy
        )
        let start = Date()
        let idle = ShellActivitySnapshot(
            sessionID: fixture.session.id,
            paneID: fixture.terminal.id,
            isBusy: false
        )

        _ = store.updateShellActivity([idle], now: start)
        _ = store.updateShellActivity([idle], now: start.addingTimeInterval(0.11))

        let activity = store.session(id: fixture.session.id)?.layout
            .documentSendTarget(for: fixture.document.id)?.shellActivity
        #expect(activity == .idle)
        #expect(
            DocumentNudgeSendBarID(
                documentID: fixture.document.id,
                shellActivity: activity
            ) != busyID
        )
    }

    private func resolve(
        _ fixture: Fixture,
        returning match: ProcessLivenessProbe.ForegroundExecutableMatch
    ) -> DocumentNudgeTargetResolution {
        DocumentPaneSendBar.resolveNudgeTarget(
            in: fixture.layout,
            for: fixture.document.id
        ) { executable, paneID in
            #expect(executable == "ssh")
            #expect(paneID == fixture.terminal.id)
            return match
        }
    }

    private func makeFixture(
        executionPlan: PaneExecutionPlan,
        shellActivity: ShellActivity = .idle
    ) -> Fixture {
        let terminal = TerminalPane(
            title: "terminal",
            workingDirectory: "/tmp",
            shellActivity: shellActivity,
            executionPlan: executionPlan
        )
        let document = DocumentPane(
            fileURL: URL(fileURLWithPath: "/tmp/a.md"),
            title: "a.md",
            associatedTerminalPaneID: terminal.id
        )
        let group = DocumentGroup(tabs: [document], selectedTabID: document.id)
        let layout = TerminalPaneLayout.split(
            TerminalSplit(
                orientation: .vertical,
                first: .pane(terminal),
                second: .documentGroup(group)
            )
        )
        let session = TerminalSession(
            title: "test",
            workingDirectory: "/tmp",
            layout: layout,
            activePaneID: terminal.id
        )
        return Fixture(
            terminal: terminal,
            document: document,
            layout: layout,
            session: session
        )
    }

    private struct Fixture {
        let terminal: TerminalPane
        let document: DocumentPane
        let layout: TerminalPaneLayout
        let session: TerminalSession
    }
}
