import AwesoMuxBridgeProtocol
import Foundation
import Testing
@testable import AwesoMuxCore

@Suite("INT-504 snapshot migration")
struct SessionSnapshotMigrationTests {
    @Test("v1 session state migrates onto its active pane", arguments: [false, true])
    func migratesLegacySessionStateOntoActivePane(legacyDisplayState: Bool) throws {
        let fixture = try Self.legacyFixture(version: 1)
        let json = String(decoding: fixture, as: UTF8.self)
        let data =
            legacyDisplayState
            ? Data(
                json.replacingOccurrences(of: #""attentionReason" : "permissionPrompt""#, with: #""agentState" : "needsAttention""#).utf8)
            : fixture
        let decoded = try SessionSnapshot.decode(from: data)
        let pane = try #require(decoded.groups.first?.sessions.first?.activePane)
        #expect(pane.agentKind == .codex)
        #expect(pane.agentExecutionState == .thinking)
        #expect(pane.attentionReason == (legacyDisplayState ? nil : .permissionPrompt))
        #expect(pane.unreadNotificationCount == 0)
    }

    @Test("v2 pane state wins over stray session keys")
    func v2SnapshotTrustsPaneStateOverStraySessionKey() throws {
        let decoded = try SessionSnapshot.decode(from: Self.legacyFixture(version: 2))
        let panes = try #require(decoded.groups.first?.sessions.first?.panes)
        #expect(panes.map(\.agentKind) == [.codex, .claudeCode])
        #expect(panes.map(\.agentExecutionState) == [.thinking, .waiting])
        #expect(panes.map(\.unreadNotificationCount) == [3, 1])
    }

    @MainActor
    @Test("v1 session-level prompt remains badged after restore")
    func v1SessionLevelPromptRestoresBadged() throws {
        let json = String(decoding: try Self.legacyFixture(version: 1), as: UTF8.self)
        let decoded = try SessionSnapshot.decode(
            from: Data(json.replacingOccurrences(of: "permissionPrompt", with: "userInputRequired").utf8))
        let store = SessionStore(restoring: decoded)
        #expect(store.selectedSession?.activePane?.attentionReason == .userInputRequired)
        #expect(store.selectedSession?.needsAcknowledgement == true)
        #expect(store.unreadNotificationTotal == 0)
    }

    @Test("garbage pane state degrades without losing the workspace", arguments: [false, true])
    func corruptPaneState(inactive: Bool) throws {
        let codex = TerminalPane(
            title: "codex", workingDirectory: "~", agentKind: .codex, agentExecutionState: .thinking, executionPlan: .local)
        let shell = TerminalPane(title: "active", workingDirectory: "~", executionPlan: .local)
        let session = TerminalSession(
            title: "split", workingDirectory: "~",
            layout: inactive ? .split(TerminalSplit(orientation: .vertical, first: .pane(shell), second: .pane(codex))) : .pane(codex),
            activePaneID: inactive ? shell.id : codex.id
        )
        let snapshot = SessionSnapshot(groups: [SessionGroup(name: "main", sessions: [session])], selectedSessionID: session.id)
        let json = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        let corrupted = json.replacingOccurrences(of: "\"thinking\"", with: inactive ? "\"corrupted-by-hand\"" : "\"wat-is-this\"")
        let decoded = try SessionSnapshot.decode(from: Data(corrupted.utf8))
        let restored = try #require(decoded.groups.first?.sessions.first)
        #expect(restored.layout.pane(id: codex.id)?.agentExecutionState == .idle)
        #expect(restored.layout.pane(id: codex.id)?.agentKind == .codex)
        #expect(restored.layout.paneCount == (inactive ? 2 : 1))
        if inactive {
            #expect(restored.layout.pane(id: shell.id)?.agentExecutionState == .idle)
        }
    }

    @Test(
        "v5 inference requires an unedited canonical title",
        arguments: [
            (0, "shell 4", AgentKind.shell, Optional(4)),
            (1, "shell 5", AgentKind.shell, nil),
            (2, "shell 6", AgentKind.codex, Optional(6)),
            (3, "shell 06", AgentKind.shell, nil),
        ])
    func legacySyntheticTitle(index: Int, title: String, kind: AgentKind, syntheticIndex: Int?) throws {
        let decoded = try SessionSnapshot.decode(from: Self.legacyFixture(version: 5))
        let sessions = try #require(decoded.groups.first?.sessions)
        try #require(sessions.indices.contains(index))
        let session = sessions[index]
        #expect(session.title == title)
        #expect(session.activeAgentKind == kind)
        #expect(session.syntheticTitle == syntheticIndex.map { SyntheticSessionTitle(agentKind: .shell, index: $0) })
    }

    @MainActor
    @Test(
        "restore preserves live prompts and drops stale attention",
        arguments: [
            (AttentionReason.userInputRequired, AgentExecutionState.idle, true),
            (.permissionPrompt, .thinking, true),
            (.permissionPrompt, .waiting, true),
            (.bell, .idle, false),
            (.processError, .error, false),
            (.desktopNotification, .idle, false),
            (.unknown, .idle, false),
        ])
    func restoredPrompt(reason: AttentionReason, execution: AgentExecutionState, kept: Bool) throws {
        let pane = TerminalPane(
            title: "codex", workingDirectory: "~", agentKind: .codex,
            agentExecutionState: execution, attentionReason: reason,
            unreadNotificationCount: 5, executionPlan: .local)
        let waiting = TerminalPane(
            title: "claude", workingDirectory: "~", agentKind: .claudeCode,
            agentExecutionState: .waiting, executionPlan: .local)
        let session = TerminalSession(
            title: "split", workingDirectory: "~",
            layout: .split(TerminalSplit(orientation: .vertical, first: .pane(pane), second: .pane(waiting))), activePaneID: pane.id)
        let snapshot = SessionSnapshot(groups: [SessionGroup(name: "main", sessions: [session])], selectedSessionID: session.id)
        let store = SessionStore(restoring: try SessionSnapshot.decode(from: JSONEncoder().encode(snapshot)))
        let restored = try #require(store.session(id: session.id)?.layout.pane(id: pane.id))
        #expect(restored.attentionReason == (kept ? reason : nil))
        #expect(restored.agentKind == (kept ? .codex : .shell))
        #expect(restored.agentExecutionState == (execution == .waiting ? .waiting : .idle))
        #expect(store.session(id: session.id)?.layout.pane(id: waiting.id)?.agentKind == .claudeCode)
        #expect(store.session(id: session.id)?.layout.pane(id: waiting.id)?.agentExecutionState == .waiting)
        #expect(store.session(id: session.id)?.needsAcknowledgement == kept)
        #expect(store.unreadNotificationTotal == 0)
        store.acknowledgeAllPanes(in: session.id)
        #expect(store.session(id: session.id)?.needsAcknowledgement == false)
    }

    private static func legacyFixture(version: Int) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Fixtures/session-state-v\(version).json")
        return try Data(contentsOf: url)
    }
}
