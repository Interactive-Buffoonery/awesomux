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
        let execution = try #require(localAmxExecution())
        var attempts = 0

        submission.submit(
            execution: execution,
            isCommandBridgeEnabled: true,
            enableCommandBridge: { true },
            connect: { _ in
                attempts += 1
                return true
            }, announce: { _ in })
        submission.submit(
            execution: execution,
            isCommandBridgeEnabled: true,
            enableCommandBridge: { true },
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
        let execution = try #require(localAmxExecution())
        var attempts = 0
        var announcements: [String] = []

        submission.submit(
            execution: execution,
            isCommandBridgeEnabled: true,
            enableCommandBridge: { true },
            connect: { _ in
                attempts += 1
                return false
            }, announce: { announcements.append($0) })

        #expect(!submission.isConnecting)
        #expect(submission.errorMessage != nil)
        #expect(announcements.count == 1)
        #expect(announcements.first == submission.errorMessage)

        submission.submit(
            execution: execution,
            isCommandBridgeEnabled: true,
            enableCommandBridge: { true },
            connect: { _ in
                attempts += 1
                return true
            }, announce: { announcements.append($0) })

        #expect(attempts == 2)
        #expect(submission.isConnecting)
        #expect(submission.errorMessage == nil)
    }

    // MARK: - Remote-owned session declaration

    /// The sheet asks for a name and nothing else — where the backend lives is
    /// the far host's problem to answer (#235).
    @Test("a session name is the whole remote-owned declaration")
    func remoteOwnedFieldsResolve() throws {
        let execution = try #require(
            SSHWorkspaceConnectFields.execution(
                destination: "my-server",
                sessionName: "  my-session  "
            ))

        #expect(execution.target.sshDestination == "my-server")
        #expect(execution.persistenceOwner == .remoteZmx)
        #expect(execution.sessionName?.rawValue == "my-session")
    }

    @Test("no session name keeps the local-amx execution unchanged")
    func noSessionNameStaysLocalAmx() throws {
        let execution = try #require(
            SSHWorkspaceConnectFields.execution(
                destination: "my-server",
                sessionName: "  "
            ))

        #expect(execution == SSHExecution(target: try #require(RemoteTarget(parsing: "my-server"))))
        #expect(execution.persistenceOwner == .localAmx)
        #expect(execution.sessionName == nil)
    }

    @Test("invalid fields resolve to no execution and explain themselves")
    func invalidFieldsAreRejected() {
        #expect(
            SSHWorkspaceConnectFields.execution(
                destination: "my-server",
                sessionName: "bad name"
            ) == nil)
        #expect(
            SSHWorkspaceConnectFields.execution(
                destination: "-oProxyCommand=example",
                sessionName: "my-session"
            ) == nil)

        #expect(SSHWorkspaceConnectFields.sessionNameMessage(for: "") == nil)
        #expect(SSHWorkspaceConnectFields.sessionNameMessage(for: " my-session ") == nil)
        #expect(SSHWorkspaceConnectFields.sessionNameMessage(for: "bad name") != nil)
        #expect(SSHWorkspaceConnectFields.sessionNameMessage(for: "-flag") != nil)
    }

    // MARK: - Command bridge gate

    @Test("a remote-owned submission connects without the local command bridge")
    func remoteOwnedSubmissionSkipsCommandBridge() throws {
        var submission = SSHWorkspaceConnectionSubmission()
        let execution = try #require(
            SSHWorkspaceConnectFields.execution(
                destination: "my-server",
                sessionName: "my-session"
            ))
        var enableAttempts = 0
        var connected = false

        submission.submit(
            execution: execution,
            isCommandBridgeEnabled: false,
            enableCommandBridge: {
                enableAttempts += 1
                return true
            },
            connect: { _ in
                connected = true
                return true
            }, announce: { _ in })

        #expect(connected)
        #expect(enableAttempts == 0)
        #expect(submission.isConnecting)
    }

    @Test("a local-amx submission still gates on the local command bridge")
    func localAmxSubmissionGatesOnCommandBridge() throws {
        var submission = SSHWorkspaceConnectionSubmission()
        let execution = try #require(localAmxExecution())
        var enableAttempts = 0
        var connected = false

        submission.submit(
            execution: execution,
            isCommandBridgeEnabled: false,
            enableCommandBridge: {
                enableAttempts += 1
                return false
            },
            connect: { _ in
                connected = true
                return true
            }, announce: { _ in })

        #expect(!connected)
        #expect(enableAttempts == 1)
        #expect(!submission.isConnecting)

        submission.submit(
            execution: execution,
            isCommandBridgeEnabled: false,
            enableCommandBridge: {
                enableAttempts += 1
                return true
            },
            connect: { _ in
                connected = true
                return true
            }, announce: { _ in })

        #expect(connected)
        #expect(enableAttempts == 2)
    }

    private func localAmxExecution() -> SSHExecution? {
        SSHWorkspaceConnectFields.execution(
            destination: "my-server",
            sessionName: ""
        )
    }
}
