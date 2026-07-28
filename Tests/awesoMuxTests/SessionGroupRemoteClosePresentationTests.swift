import AwesoMuxCore
import Testing
@testable import awesoMux

@Suite("Session group remote close presentation")
struct SessionGroupRemoteClosePresentationTests {
    private let target = RemoteTarget(user: "alice", host: "alpha")!
    private let otherTarget = RemoteTarget(user: "bob", host: "beta")!

    /// A pane a local `amx` daemon keeps alive around its SSH child.
    private func localAmxSession(on target: RemoteTarget) -> TerminalSession {
        TerminalSession(
            title: "remote",
            workingDirectory: "~",
            executionPlan: .ssh(SSHExecution(target: target))
        )
    }

    /// A pane whose zmx session the remote host owns — it outlives any close.
    private func remoteOwnedSession(on target: RemoteTarget) -> TerminalSession {
        let execution = SSHExecution(
            target: target,
            persistenceOwner: .remoteZmx,
            sessionName: RemoteSessionName(rawValue: "work")!
        )!
        return TerminalSession(
            title: "remote-owned",
            workingDirectory: "~",
            executionPlan: .ssh(execution)
        )
    }

    @Test("local-only groups have no remote close impact")
    func localOnly() {
        let presentation = SessionGroupRemoteClosePresentation(
            summary: SessionGroupExecutionSummary(
                sessions: [TerminalSession(title: "local", workingDirectory: "~")]
            ),
            isEmpty: false
        )

        #expect(!presentation.requiresConfirmation)
        #expect(presentation.lossText == nil)
    }

    @Test("default-only impact never claims active remote work")
    func defaultOnly() {
        let empty = SessionGroupRemoteClosePresentation(
            summary: SessionGroupExecutionSummary(sessions: [], defaultTarget: target),
            isEmpty: true
        )
        let local = SessionGroupRemoteClosePresentation(
            summary: SessionGroupExecutionSummary(
                sessions: [TerminalSession(title: "local", workingDirectory: "~")],
                defaultTarget: target
            ),
            isEmpty: false
        )

        #expect(empty.requiresConfirmation)
        #expect(empty.lossText == "Removing this group removes its SSH creation default alice@alpha. No active remote panes are affected.")
        #expect(local.requiresConfirmation)
        #expect(local.lossText == "Closing this group removes its SSH creation default alice@alpha. Its panes are local.")
    }

    @Test("locally kept remote panes are named as unreachable after the close")
    func activeRemoteWithoutDefault() throws {
        let presentation = SessionGroupRemoteClosePresentation(
            summary: SessionGroupExecutionSummary(sessions: [localAmxSession(on: target)]),
            isEmpty: false
        )

        let lossText = try #require(presentation.lossText)
        #expect(presentation.requiresConfirmation)
        #expect(lossText.contains("alice@alpha"))
        #expect(ClosePresentationClaims.saysSomethingKeepsRunning(lossText) == false)
        #expect(ClosePresentationClaims.saysAwesoMuxLosesThePane(lossText))
    }

    /// The behaviour under test: a remote-owned zmx session survives the close
    /// by design (ADR-0023 amendment #214), so the confirmation must not say
    /// awesoMux ends it.
    @Test("remote-owned panes are never described as destroyed by the close")
    func remoteOwnedOnly() throws {
        let presentation = SessionGroupRemoteClosePresentation(
            summary: SessionGroupExecutionSummary(sessions: [remoteOwnedSession(on: target)]),
            isEmpty: false
        )

        let lossText = try #require(presentation.lossText)
        #expect(lossText.contains("alice@alpha"))
        #expect(ClosePresentationClaims.claimsDestruction(lossText) == false)
        #expect(ClosePresentationClaims.saysSomethingKeepsRunning(lossText))
    }

    @Test("mixed groups separate the panes that survive from the ones that don't")
    func mixedPersistenceOwners() throws {
        let presentation = SessionGroupRemoteClosePresentation(
            summary: SessionGroupExecutionSummary(
                sessions: [
                    TerminalSession(title: "local", workingDirectory: "~"),
                    localAmxSession(on: target),
                    remoteOwnedSession(on: otherTarget),
                ]
            ),
            isEmpty: false
        )

        let lossText = try #require(presentation.lossText)
        // Each destination is claimed by exactly one outcome: alpha's pane is
        // lost with the close, beta's session keeps running on its host.
        let sentences = lossText.split(separator: ".").map(String.init)
        let lostSentence = try #require(
            sentences.first(where: ClosePresentationClaims.saysAwesoMuxLosesThePane)
        )
        let keptSentence = try #require(
            sentences.first(where: ClosePresentationClaims.saysSomethingKeepsRunning)
        )
        #expect(lostSentence.contains("alice@alpha"))
        #expect(!lostSentence.contains("bob@beta"))
        #expect(keptSentence.contains("bob@beta"))
        #expect(!keptSentence.contains("alice@alpha"))
    }

    @Test("a remote-owned pane on the same host as a local-amx pane appears in both outcomes")
    func sameDestinationBothOwners() throws {
        let presentation = SessionGroupRemoteClosePresentation(
            summary: SessionGroupExecutionSummary(
                sessions: [localAmxSession(on: target), remoteOwnedSession(on: target)]
            ),
            isEmpty: false
        )

        let lossText = try #require(presentation.lossText)
        #expect(ClosePresentationClaims.saysAwesoMuxLosesThePane(lossText))
        #expect(ClosePresentationClaims.saysSomethingKeepsRunning(lossText))
    }
}
