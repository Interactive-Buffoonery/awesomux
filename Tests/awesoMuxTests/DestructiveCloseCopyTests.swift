import AwesoMuxCore
import Testing
@testable import awesoMux

@Suite("Destructive close copy")
struct DestructiveCloseCopyTests {
    private let target = RemoteTarget(user: "alice", host: "alpha")!
    private let otherTarget = RemoteTarget(user: "bob", host: "beta")!

    private func localAmxSession(on target: RemoteTarget) -> TerminalSession {
        TerminalSession(
            title: "remote",
            workingDirectory: "~",
            executionPlan: .ssh(SSHExecution(target: target))
        )
    }

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

    private func body(_ sessions: [TerminalSession], atRisk: Bool = false) -> String {
        DestructiveCloseCopy.clearWorkspaceBody(
            title: "Work",
            hasInterruptedActivity: atRisk,
            summary: SessionGroupExecutionSummary(sessions: sessions)
        )
    }

    @Test("a local workspace is told its sessions end, and nothing survives it")
    func localOnly() {
        let text = body([TerminalSession(title: "local", workingDirectory: "~")])

        #expect(text.contains("Work"))
        #expect(ClosePresentationClaims.claimsDestruction(text))
        #expect(!ClosePresentationClaims.saysSomethingKeepsRunning(text))
    }

    @Test("local-amx SSH panes still count as sessions the close ends")
    func localAmxRemote() {
        let text = body([localAmxSession(on: target)])

        #expect(ClosePresentationClaims.claimsDestruction(text))
        #expect(!ClosePresentationClaims.saysSomethingKeepsRunning(text))
    }

    /// `killClearedDaemons` only issues local `amx` kills, and a remote-owned
    /// pane has no local daemon — its zmx session keeps running on the far host
    /// (ADR-0023 amendment #214). The dialog must not claim otherwise.
    @Test("an all-remote-owned workspace is never promised a termination")
    func remoteOwnedOnly() {
        let text = body([remoteOwnedSession(on: target)])

        #expect(text.contains("Work"))
        #expect(text.contains("alice@alpha"))
        #expect(!ClosePresentationClaims.claimsDestruction(text))
        #expect(ClosePresentationClaims.saysSomethingKeepsRunning(text))
    }

    @Test("a mixed workspace makes both claims, each scoped to its own panes")
    func mixedOwners() throws {
        let text = body([
            TerminalSession(title: "local", workingDirectory: "~"),
            remoteOwnedSession(on: otherTarget),
        ])

        let sentences = text.split(separator: ".").map(String.init)
        let endedSentence = try #require(
            sentences.first(where: ClosePresentationClaims.claimsDestruction)
        )
        let keptSentence = try #require(
            sentences.first(where: ClosePresentationClaims.saysSomethingKeepsRunning)
        )
        #expect(!endedSentence.contains("bob@beta"))
        #expect(keptSentence.contains("bob@beta"))
    }

    @Test("every remote-owned destination is named")
    func listsEveryRemoteOwnedDestination() {
        let text = body([
            remoteOwnedSession(on: target),
            remoteOwnedSession(on: otherTarget),
        ])

        #expect(text.contains("alice@alpha"))
        #expect(text.contains("bob@beta"))
        #expect(!ClosePresentationClaims.claimsDestruction(text))
    }

    @Test("running activity adds an interruption warning without changing the claims")
    func riskyWorkspaceKeepsPersistenceClaims() {
        let calm = body([remoteOwnedSession(on: target)])
        let risky = body([remoteOwnedSession(on: target)], atRisk: true)

        #expect(!calm.localizedCaseInsensitiveContains("interrupted"))
        #expect(risky.localizedCaseInsensitiveContains("interrupted"))
        #expect(!ClosePresentationClaims.claimsDestruction(risky))
        #expect(ClosePresentationClaims.saysSomethingKeepsRunning(risky))
    }
}
