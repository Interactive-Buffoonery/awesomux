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
}
