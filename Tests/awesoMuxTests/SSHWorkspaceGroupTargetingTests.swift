import AwesoMuxCore
import Foundation
import Testing
@testable import awesoMux

@Suite("SSH workspace group targeting")
struct SSHWorkspaceGroupTargetingTests {
    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

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

    @Test("connect sheet guards duplicate submissions and recovers rejected requests")
    func connectSheetSubmissionWiring() throws {
        let source = try source("Sources/awesoMux/Views/SSHWorkspaceConnectSheet.swift")

        #expect(source.contains("@State private var isConnecting = false"))
        #expect(source.contains("guard !isConnecting, let target else { return }"))
        #expect(source.contains(".disabled(target == nil || isConnecting)"))
        #expect(source.contains("if !onConnect(target)"))
        #expect(source.contains("isConnecting = false"))
    }

    @Test("settings failures are announced from every managed SSH entry point")
    func settingsFailureAnnouncementWiring() throws {
        for path in [
            "Sources/awesoMux/Views/SSHWorkspaceConnectSheet.swift",
            "Sources/awesoMux/Views/RemoteWorkspaceGroupCreateSheet.swift",
            "Sources/awesoMux/Views/RemotePaneDisconnectedView.swift",
        ] {
            let source = try source(path)
            #expect(source.contains("TerminalAccessibilityAnnouncer.announce(settingsErrorMessage, priority: .high)"))
        }
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.packageRoot.appending(path: path), encoding: .utf8)
    }
}
