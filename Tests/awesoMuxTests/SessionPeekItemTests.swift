// Tests/awesoMuxTests/SessionPeekItemTests.swift
import AwesoMuxCore
import DesignSystem
import Testing
@testable import awesoMux

@Suite("Session peek item (group roster rows)")
struct SessionPeekItemTests {
    @Test("items(for:activeSessionID:) preserves order and marks the active session")
    func itemsPreserveOrderAndActiveFlag() {
        let alpha = TerminalSession(
            title: "Alpha",
            workingDirectory: "/tmp/alpha",
            agentKind: .shell,
            agentState: .idle
        )
        let beta = TerminalSession(
            title: "Beta",
            workingDirectory: "/tmp/beta",
            agentKind: .claudeCode,
            agentState: .needsAttention
        )

        let items = SessionPeekItem.items(for: [alpha, beta], activeSessionID: beta.id)

        #expect(items.map(\SessionPeekItem.id) == [alpha.id, beta.id])
        #expect(items.map(\SessionPeekItem.title) == ["Alpha", "Beta"])
        #expect(items[0].isActive == false)
        #expect(items[1].isActive == true)
    }

    @Test("remote session names its exact declared target")
    func remoteSessionNamesTarget() {
        let pane = TerminalPane(
            title: "remote",
            workingDirectory: "/tmp",
            remoteHost: "box.example.com",
            executionPlan: .ssh(SSHExecution(target: RemoteTarget(user: "", host: "box.example.com")!))
        )
        let session = TerminalSession(
            title: "Remote",
            workingDirectory: "/tmp",
            layout: .pane(pane),
            activePaneID: pane.id
        )

        let items = SessionPeekItem.items(for: [session], activeSessionID: TerminalSession.ID?.none)

        #expect(items[0].locationText == "SSH · box.example.com")
        #expect(items[0].accessibilityLocationText == "Remote panes on box.example.com")
    }

    @Test("multi-pane session describes mixed locations")
    func mixedSessionNamesLocations() {
        let target = RemoteTarget(user: "alice", host: "box.example.com")!
        let local = TerminalPane(title: "local", workingDirectory: "~", executionPlan: .local)
        let remote = TerminalPane(
            title: "remote",
            workingDirectory: "~",
            executionPlan: .ssh(SSHExecution(target: target))
        )
        let session = TerminalSession(
            title: "Mixed",
            workingDirectory: "~",
            layout: .split(
                TerminalSplit(
                    orientation: .vertical,
                    first: .pane(local),
                    second: .pane(remote)
                )
            ),
            activePaneID: local.id
        )

        let item = SessionPeekItem.items(for: [session], activeSessionID: nil)[0]

        #expect(item.locationText == "Mixed locations")
        #expect(item.accessibilityLocationText == "Local and remote panes on alice@box.example.com")
    }
}
