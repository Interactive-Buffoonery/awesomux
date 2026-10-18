import AwesoMuxBridgeProtocol
import Foundation
import Testing
@testable import AwesoMuxCore

/// Covers `WorkspaceAttentionReducer.updatePane`'s `PaneUpdateOutcome.didMutate`
/// gate and the coarsened activity heartbeat it enables (perf/main-thread-churn).
/// A same-state repeat (Claude Code emits these continuously while streaming)
/// must report `didMutate == false` so the store skips the whole-store
/// `@Observable` publish, while a real field change or a due heartbeat refresh
/// must still report `true`.
@Suite("WorkspaceAttentionReducer heartbeat coarsening")
struct WorkspaceAttentionReducerHeartbeatTests {
    private static let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func makeSession(
        agentKind: AgentKind = .claudeCode,
        agentExecutionState: AgentExecutionState = .thinking
    ) -> TerminalSession {
        TerminalSession(
            title: "claude",
            workingDirectory: "~",
            agentKind: agentKind,
            agentExecutionState: agentExecutionState,
            lastAgentStateChangeAt: Self.t0
        )
    }

    @Test(arguments: [
        ([WorkspaceAttentionReducer.SessionUpdate(agentExecutionState: .thinking)], [1.0], false, false),
        ([WorkspaceAttentionReducer.SessionUpdate(agentExecutionState: .thinking)], [11.0], true, true),
        ([WorkspaceAttentionReducer.SessionUpdate(agentExecutionState: .output)], [1.0], true, true),
        ([WorkspaceAttentionReducer.SessionUpdate(agentKind: .claudeCode)], [1.0], true, false),
        ([WorkspaceAttentionReducer.SessionUpdate(title: "new")], [1.0], true, false),
        ([WorkspaceAttentionReducer.SessionUpdate(attentionReason: .bell)], [2.0], true, false),
        ([WorkspaceAttentionReducer.SessionUpdate(unreadNotificationDelta: 1)], [3.0], true, false),
        (
            [WorkspaceAttentionReducer.SessionUpdate(title: "new"), WorkspaceAttentionReducer.SessionUpdate(title: "new")], [1.0, 4.0],
            false, false
        ),
    ])
    func updateMutation(updates: [WorkspaceAttentionReducer.SessionUpdate], offsets: [Double], didMutate: Bool, stampMoved: Bool) {
        var session = makeSession(agentKind: .codex)
        for (index, update) in updates.enumerated() {
            let now = Self.t0.addingTimeInterval(offsets[index])
            let outcome = WorkspaceAttentionReducer.updatePane(&session, paneID: session.activePaneID, update: update, now: now)
            if index == updates.count - 1 {
                #expect(outcome.didMutate == didMutate)
                #expect(session.lastAgentStateChangeAt == (stampMoved ? now : Self.t0))
                if let state = update.agentExecutionState { #expect(session.agentExecutionState == state) }
                if let kind = update.agentKind { #expect(session.agentKind == kind) }
                if let title = update.title { #expect(session.title == title) }
                if let reason = update.attentionReason { #expect(session.attentionReason == reason) }
                if update.unreadNotificationDelta == 1 {
                    #expect(outcome.unreadChange?.oldCount == 0)
                    #expect(outcome.unreadChange?.newCount == 1)
                } else {
                    #expect(outcome.unreadChange == nil)
                }
            }
        }
    }

}
