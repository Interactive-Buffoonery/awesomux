import AwesoMuxBridgeProtocol
import Foundation
import Testing
@testable import AwesoMuxCore

@Suite
struct CodexPermissionNotificationTests {
    private let start = Date(timeIntervalSince1970: 100)

    private func session(reason: AttentionReason? = .permissionPrompt) -> TerminalSession {
        TerminalSession(
            title: "codex", workingDirectory: "~",
            layout: .pane(
                TerminalPane(
                    title: "codex", workingDirectory: "~", agentKind: .codex,
                    agentExecutionState: .thinking, attentionReason: reason,
                    unreadNotificationCount: 1, executionPlan: .local
                ))
        )
    }

    @Test
    func persistentPermissionNotifiesOnceAfterGrace() {
        let groups = [SessionGroup(name: "test", sessions: [session()])]
        var tracker = WorkspaceNotificationTracker()
        #expect({ tracker.notificationEvents(afterUpdating: groups, selectedSessionID: nil, now: start) }().isEmpty)
        #expect(tracker.nextNotificationDeadline == start.addingTimeInterval(10))
        #expect({ tracker.notificationEvents(afterUpdating: groups, selectedSessionID: nil, now: start.addingTimeInterval(9)) }().isEmpty)
        #expect(tracker.nextNotificationDeadline == start.addingTimeInterval(10))
        #expect(
            { tracker.notificationEvents(afterUpdating: groups, selectedSessionID: nil, now: start.addingTimeInterval(10)) }().count == 1)
        #expect(tracker.nextNotificationDeadline == nil)
        #expect({ tracker.notificationEvents(afterUpdating: groups, selectedSessionID: nil, now: start.addingTimeInterval(20)) }().isEmpty)
    }

    @Test
    func resolvedPermissionCancelsNotification() {
        var paneSession = session()
        var tracker = WorkspaceNotificationTracker()
        #expect(
            {
                tracker.notificationEvents(
                    afterUpdating: [SessionGroup(name: "test", sessions: [paneSession])], selectedSessionID: nil, now: start)
            }().isEmpty)
        _ = WorkspaceAttentionReducer.updatePane(
            &paneSession, paneID: paneSession.activePaneID,
            update: .init(clearsAttention: true, attentionClearIsAuthoritative: true, clearsUnreadNotifications: true),
            now: start.addingTimeInterval(4)
        )
        #expect(
            {
                tracker.notificationEvents(
                    afterUpdating: [SessionGroup(name: "test", sessions: [paneSession])], selectedSessionID: nil,
                    now: start.addingTimeInterval(10))
            }().isEmpty)
        #expect(tracker.nextNotificationDeadline == nil)
    }

    @Test
    func otherAttentionRemainsImmediate() {
        let groups = [SessionGroup(name: "test", sessions: [session(reason: .userInputRequired)])]
        var tracker = WorkspaceNotificationTracker()
        #expect({ tracker.notificationEvents(afterUpdating: groups, selectedSessionID: nil, now: start) }().count == 1)
        #expect(tracker.nextNotificationDeadline == nil)
    }
}
