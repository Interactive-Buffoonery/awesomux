import AwesoMuxCore
import Testing
@testable import awesoMux

@Suite("SSH workspace group targeting")
struct SSHWorkspaceGroupTargetingTests {
    @Test("sheet validation rejects option-like text and keeps aliases")
    func destinationValidation() {
        #expect(SSHWorkspaceDestinationValidation.target(from: "my-server")?.sshDestination == "my-server")
        #expect(SSHWorkspaceDestinationValidation.target(from: "alice@my-server")?.sshDestination == "alice@my-server")
        #expect(SSHWorkspaceDestinationValidation.target(from: "-oProxyCommand=example") == nil)
        #expect(SSHWorkspaceDestinationValidation.message(for: "") == nil)
        #expect(SSHWorkspaceDestinationValidation.message(for: "my-server") == nil)
        #expect(SSHWorkspaceDestinationValidation.message(for: "user@") != nil)
        #expect(SSHWorkspaceDestinationValidation.message(for: "-oProxyCommand=example") != nil)
    }

    @Test("default group matching is case insensitive when nothing is selected")
    func caseInsensitiveDefaultGroup() throws {
        let fallback = SessionGroup(name: "awesoMux", sessions: [])
        let expected = SessionGroup(name: "Work", sessions: [])

        let resolved = try #require(
            SSHWorkspaceGroupTargeting.resolve(
                groups: [fallback, expected],
                selectedSessionID: nil,
                defaultGroupName: "work"
            ))

        #expect(resolved.id == expected.id)
    }

    @Test("confusable default name diverts to the canonical group like all routing")
    func confusableDefaultGroupDiverts() throws {
        let canonical = SessionGroup(name: "awesoMux", sessions: [])
        let decoy = SessionGroup(name: "Work", sessions: [])

        let resolved = try #require(
            SSHWorkspaceGroupTargeting.resolve(
                groups: [decoy, canonical],
                selectedSessionID: nil,
                // Cyrillic С/а/е mixed into Latin — groupLookupKey sends this
                // to the canonical default (INT-485); the resolver must agree.
                defaultGroupName: "\u{0421}l\u{0430}ud\u{0435}"
            ))

        #expect(resolved.id == canonical.id)
    }

    @Test("selected workspace group wins over the configured default")
    func selectedGroupWins() throws {
        let selected = TerminalSession(title: "shell 1", workingDirectory: "~")
        let selectedGroup = SessionGroup(name: "Selected", sessions: [selected])
        let defaultGroup = SessionGroup(name: "Work", sessions: [])

        let resolved = try #require(
            SSHWorkspaceGroupTargeting.resolve(
                groups: [defaultGroup, selectedGroup],
                selectedSessionID: selected.id,
                defaultGroupName: "work"
            ))

        #expect(resolved.id == selectedGroup.id)
    }

    @Test("connect submission blocks duplicates")
    func connectSubmissionBlocksDuplicates() throws {
        var submission = SSHWorkspaceConnectionSubmission()
        let target = try #require(RemoteTarget(parsing: "my-server"))
        var attempts = 0

        submission.submit(
            target: target,
            connect: { _ in
                attempts += 1
                return true
            }, announce: { _ in })
        submission.submit(
            target: target,
            connect: { _ in
                attempts += 1
                return true
            }, announce: { _ in })

        #expect(attempts == 1)
        #expect(submission.isConnecting)
    }

    @Test("rejected connect submissions show and announce an error, then allow retry")
    func rejectedConnectSubmissionRecovers() throws {
        var submission = SSHWorkspaceConnectionSubmission()
        let target = try #require(RemoteTarget(parsing: "my-server"))
        var attempts = 0
        var announcements: [String] = []

        submission.submit(
            target: target,
            connect: { _ in
                attempts += 1
                return false
            }, announce: { announcements.append($0) })

        #expect(!submission.isConnecting)
        #expect(submission.errorMessage != nil)
        #expect(announcements.count == 1)
        #expect(announcements.first == submission.errorMessage)

        submission.submit(
            target: target,
            connect: { _ in
                attempts += 1
                return true
            }, announce: { announcements.append($0) })

        #expect(attempts == 2)
        #expect(submission.isConnecting)
        #expect(submission.errorMessage == nil)
    }
}
