import AwesoMuxCore
import Foundation
import Testing
@testable import awesoMux

@MainActor
@Suite("Document nudge foreground gate")
struct DocumentNudgeForegroundGateTests {
    @Test(
        "declared local panes require foreground evidence that is not SSH",
        arguments: [
            ProcessLivenessProbe.ForegroundExecutableMatch.matching,
            .unknown,
        ])
    func rejectsUnsafeForegroundEvidence(
        _ match: ProcessLivenessProbe.ForegroundExecutableMatch
    ) {
        let fixture = makeFixture(executionPlan: .local)

        #expect(
            resolve(fixture, returning: match) == .unavailable(.requiresLocalTerminal)
        )
    }

    @Test("declared local pane becomes eligible on the next safe foreground check")
    func rechecksForegroundEvidence() {
        let fixture = makeFixture(executionPlan: .local)

        #expect(resolve(fixture, returning: .matching) == .unavailable(.requiresLocalTerminal))
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

    @Test("availability and activation resolve through the same foreground gate")
    func availabilityAndActivationParity() {
        let fixture = makeFixture(executionPlan: .local)
        var checks = 0
        let probe: (String, TerminalPane.ID) -> ProcessLivenessProbe.ForegroundExecutableMatch = {
            executable, paneID in
            checks += 1
            #expect(executable == "ssh")
            #expect(paneID == fixture.terminal.id)
            return .matching
        }

        let availability = DocumentPaneSendBar.resolveNudgeTarget(
            in: fixture.layout,
            for: fixture.document.id,
            foregroundExecutableMatch: probe
        )
        let activation = DocumentPaneSendBar.resolveNudgeTarget(
            in: fixture.layout,
            for: fixture.document.id,
            foregroundExecutableMatch: probe
        )

        #expect(availability == activation)
        #expect(checks == 2)
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

    private func makeFixture(executionPlan: PaneExecutionPlan) -> Fixture {
        let terminal = TerminalPane(
            title: "terminal",
            workingDirectory: "/tmp",
            executionPlan: executionPlan
        )
        let document = DocumentPane(
            fileURL: URL(fileURLWithPath: "/tmp/a.md"),
            title: "a.md",
            associatedTerminalPaneID: terminal.id
        )
        let group = DocumentGroup(tabs: [document], selectedTabID: document.id)
        return Fixture(
            terminal: terminal,
            document: document,
            layout: .split(
                TerminalSplit(
                    orientation: .vertical,
                    first: .pane(terminal),
                    second: .documentGroup(group)
                )
            )
        )
    }

    private struct Fixture {
        let terminal: TerminalPane
        let document: DocumentPane
        let layout: TerminalPaneLayout
    }
}
